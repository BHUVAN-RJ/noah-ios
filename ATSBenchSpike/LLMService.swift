//
//  LLMService.swift
//  ATSBenchSpike
//

import Foundation
import Combine
import Darwin
import MLX
import MLXLLM
import MLXLMCommon
import OSLog

private let log = Logger(subsystem: "ATSBenchSpike", category: "LLM")

// MARK: — Types

enum LoadState {
    case idle
    case downloading(Double)   // 0.0 – 1.0
    case ready
    case failed(String)
}

enum LLMServiceError: LocalizedError {
    case notLoaded

    var errorDescription: String? {
        "Model is not loaded. Tap Download to fetch it first."
    }
}

struct RunMetrics {
    let modelID: String
    let loadTimeSeconds: Double
    let promptTokens: Int
    let generationTokens: Int
    let promptTokensPerSecond: Double
    let tokensPerSecond: Double
    let totalWallSeconds: Double
    let mlxActiveMB: Double
    let physicalFootprintMB: Double
    let timeToFirstTokenSeconds: Double
    let onDiskMB: Double
    let generatedText: String

    func summary() -> String {
        let shortName = modelID.components(separatedBy: "/").last ?? modelID
        let params = Self.parseParamSize(from: modelID)
        let quant = Self.parseQuantization(from: modelID)
        return """
        ── \(shortName) [\(params) · \(quant)] ──
        On-disk size     : \(String(format: "%.0f", onDiskMB)) MB
        Cold load time   : \(String(format: "%.2f", loadTimeSeconds)) s
        Time to 1st token: \(String(format: "%.2f", timeToFirstTokenSeconds)) s
        Prompt           : \(promptTokens) tok  (\(String(format: "%.1f", promptTokensPerSecond)) tok/s)
        Decode throughput: \(generationTokens) tok  (\(String(format: "%.1f", tokensPerSecond)) tok/s)
        Total gen time   : \(String(format: "%.2f", totalWallSeconds)) s
        Peak resident    : \(String(format: "%.0f", physicalFootprintMB)) MB
        MLX active       : \(String(format: "%.0f", mlxActiveMB)) MB
        ── Answer ──
        \(generatedText)
        """
    }

    private static func parseQuantization(from modelID: String) -> String {
        let lower = modelID.lowercased()
        if lower.contains("4bit") { return "4-bit" }
        if lower.contains("8bit") { return "8-bit" }
        return "unknown quant"
    }

    private static func parseParamSize(from modelID: String) -> String {
        let pattern = #"(\d+\.?\d*[Bb])"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: modelID, range: NSRange(modelID.startIndex..., in: modelID)),
              let range = Range(match.range(at: 1), in: modelID) else { return "?" }
        return String(modelID[range]).uppercased()
    }
}

// Used to smuggle first-token timestamp out of the generate callback,
// which runs inside container.perform's isolated context.
private final class FirstTokenCapture: @unchecked Sendable {
    var time: Date?
}

// MARK: — Model catalogue (add more here)

struct ModelEntry: Identifiable, Hashable {
    let id: String        // HuggingFace repo id
    let displayName: String
}

// MARK: — Service

@MainActor
final class LLMService: ObservableObject {

    static let availableModels: [ModelEntry] = [
        ModelEntry(id: "mlx-community/Qwen3-1.7B-4bit",            displayName: "Qwen3 1.7B 4-bit"),
        ModelEntry(id: "mlx-community/Llama-3.2-3B-Instruct-4bit", displayName: "Llama 3.2 3B 4-bit"),
    ]

    // ── Generation knobs ───────────────────────────────────────────────────
    private static let maxTokens = 400
    private static let temperature: Float = 0.6
    private static let topP: Float = 0.9

    // ── System prompt ───────────────────────────────────────────────────────
    private static let systemPromptBody = """
        You are a professional job-application assistant. \
        The user will provide their background and the job/company context. \
        You MUST draw on specific details from that background and context in your answer — \
        do not write a generic response. \
        Write a concise, first-person, ready-to-send answer in a confident and professional tone. \
        Output only the answer text itself — no preamble, no labels, no meta-commentary.
        """

    // ── Published state ────────────────────────────────────────────────────
    @Published var selectedModel: ModelEntry = availableModels[0]
    @Published var loadState: LoadState = .idle
    @Published var output: String = ""
    @Published var metrics: RunMetrics?
    @Published var isGenerating: Bool = false

    private var container: ModelContainer?
    private var loadStartTime: Date?
    private var loadTimeSeconds: Double = 0

    var currentModelID: String { selectedModel.id }

    // MARK: — Load

    func downloadAndLoad() async {
        if case .ready = loadState { return }
        if case .downloading = loadState { return }

        // Compute a safe MLX memory ceiling based on Metal's recommended working-set
        // size for this device. Leaving headroom prevents jetsam from killing the
        // process and lets MLX throw a catchable Swift error instead.
        //
        // iPhone 16 Pro (A18 Pro, 8 GB) — recommendedMaxWorkingSetSize ≈ 5 GB
        // Jetsam limit (no increased-memory entitlement) ≈ 3–3.5 GB phys footprint
        // We cap MLX at 55 % of recommended, which is ≈ 2.75 GB on this device.
        let deviceInfo = GPU.deviceInfo()
        let mlxCap = Int(Double(deviceInfo.maxRecommendedWorkingSetSize) * 0.55)
        GPU.set(memoryLimit: mlxCap, relaxed: false)
        GPU.set(cacheLimit: 128 * 1024 * 1024)

        loadState = .downloading(0)
        loadStartTime = Date()
        let modelID = currentModelID
        let memBefore = GPU.snapshot()
        let physBeforeLoad = physicalFootprintMB()
        log.info("[\(modelID)] Loading — MLX cap: \(mlxCap / 1_048_576) MB  active before: \(memBefore.activeMemory / 1_048_576) MB  phys: \(String(format: "%.0f", physBeforeLoad)) MB")

        do {
            let config = ModelConfiguration(id: modelID)

            let loadedContainer = try await LLMModelFactory.shared.loadContainer(
                configuration: config
            ) { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.loadState = .downloading(progress.fractionCompleted)
                }
            }

            let elapsed = Date().timeIntervalSince(loadStartTime ?? Date())
            loadTimeSeconds = elapsed
            container = loadedContainer

            let memAfter = GPU.snapshot()
            let physMBAfterLoad = physicalFootprintMB()
            log.info("[\(modelID)] Ready in \(String(format: "%.2f", elapsed)) s — MLX active: \(memAfter.activeMemory / 1_048_576) MB  phys: \(String(format: "%.0f", physMBAfterLoad)) MB")
            loadState = .ready

        } catch {
            let description = error.localizedDescription
            let classified = classifyLoadError(error)
            loadState = .failed(classified)
            log.error("[\(modelID)] Load failed (\(classified)): \(description)")
        }
    }

    func retry() async {
        await releaseCurrentModel()
        loadState = .idle
        await downloadAndLoad()
    }

    func selectModel(_ entry: ModelEntry) async {
        guard entry.id != selectedModel.id || container == nil else { return }

        let physBefore = physicalFootprintMB()
        log.info("[selectModel] Releasing — phys: \(String(format: "%.0f", physBefore)) MB")
        await releaseCurrentModel()
        let physAfter = physicalFootprintMB()
        log.info("[selectModel] Released  — phys: \(String(format: "%.0f", physAfter)) MB")

        loadTimeSeconds = 0
        output = ""
        metrics = nil
        selectedModel = entry
        loadState = .idle
        await downloadAndLoad()
    }

    // MARK: — Generate

    @discardableResult
    func generate(
        question: String,
        userBackground: String,
        jobContext: String
    ) async throws -> String {
        guard let container else { throw LLMServiceError.notLoaded }

        isGenerating = true
        output = ""
        metrics = nil
        defer { isGenerating = false }

        let systemContent = buildSystemContent()
        let userContent = buildUserContent(
            question: question,
            userBackground: userBackground,
            jobContext: jobContext
        )

        let parameters = GenerateParameters(
            maxTokens: Self.maxTokens,
            temperature: Self.temperature,
            topP: Self.topP
        )

        let modelID = currentModelID
        log.info("[\(modelID)] Starting generation")
        let wallStart = Date()
        let firstTokenCapture = FirstTokenCapture()

        let result = try await container.perform { [systemContent, userContent, parameters, firstTokenCapture] context in
            let chatMessages: [Chat.Message] = [
                .system(systemContent),
                .user(userContent)
            ]
            let userInput = UserInput(chat: chatMessages)
            let lmInput = try await context.processor.prepare(input: userInput)
            return try MLXLMCommon.generate(
                input: lmInput,
                parameters: parameters,
                context: context
            ) { (_: [Int]) in
                if firstTokenCapture.time == nil { firstTokenCapture.time = Date() }
                return GenerateDisposition.more
            }
        }

        let wallSeconds = Date().timeIntervalSince(wallStart)
        let timeToFirstToken = firstTokenCapture.time.map { $0.timeIntervalSince(wallStart) } ?? wallSeconds
        let mlxSnap = GPU.snapshot()
        let cleanOutput = stripThinkingBlock(from: result.output)

        let runMetrics = RunMetrics(
            modelID: modelID,
            loadTimeSeconds: loadTimeSeconds,
            promptTokens: result.promptTokenCount,
            generationTokens: result.generationTokenCount,
            promptTokensPerSecond: result.promptTokensPerSecond,
            tokensPerSecond: result.tokensPerSecond,
            totalWallSeconds: wallSeconds,
            mlxActiveMB: Double(mlxSnap.activeMemory) / 1_048_576,
            physicalFootprintMB: physicalFootprintMB(),
            timeToFirstTokenSeconds: timeToFirstToken,
            onDiskMB: onDiskSizeMB(for: modelID),
            generatedText: cleanOutput
        )

        output = cleanOutput
        metrics = runMetrics
        log.info("\(runMetrics.summary())")

        return cleanOutput
    }

    // MARK: — Private helpers

    private func releaseCurrentModel() async {
        container = nil
        // ModelContainer is an actor; its deinit (which moves weight buffers
        // from "active" to "cache") may be scheduled asynchronously. Two yields
        // give the executor a chance to run it before we call clearCache().
        await Task.yield()
        GPU.clearCache()
        await Task.yield()
        GPU.clearCache()
        let mem = GPU.snapshot()
        let physAfterRelease = physicalFootprintMB()
        log.info("[release] MLX active: \(mem.activeMemory / 1_048_576) MB  cache: \(mem.cacheMemory / 1_048_576) MB  phys: \(String(format: "%.0f", physAfterRelease)) MB")
    }

    // Computes the total on-disk size of the Hub-cached model folder.
    // Hub stores models at <caches>/huggingface/hub/models--{org}--{repo}/
    private func onDiskSizeMB(for modelID: String) -> Double {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return 0 }
        let dirName = "models--" + modelID.replacingOccurrences(of: "/", with: "--")
        let modelDir = caches.appendingPathComponent("huggingface/hub/\(dirName)")
        return directorySize(at: modelDir) / 1_048_576
    }

    private func directorySize(at url: URL) -> Double {
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: .skipsHiddenFiles
        ) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            total += (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        }
        return Double(total)
    }

    // Classifies a model-load error so the user can distinguish OOM (model
    // too large for device) from a missing/corrupt file.
    private func classifyLoadError(_ error: Error) -> String {
        let msg = error.localizedDescription.lowercased()
        let isOOM = msg.contains("memory") || msg.contains("allocation")
            || msg.contains("limit") || msg.contains("metal")
        if isOOM {
            return "Out of memory — model likely too large for this device without the increased-memory entitlement."
        }
        let isMissingFile = msg.contains("no such file") || msg.contains("not found")
            || msg.contains("missing") || msg.contains("decode")
        if isMissingFile {
            return "File error — model folder may be missing or corrupt."
        }
        return error.localizedDescription
    }

    // Returns physical memory footprint via task_info (same value Instruments shows).
    private func physicalFootprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    // Strips <think>…</think> blocks that Qwen3 emits even in no-think mode.
    private func stripThinkingBlock(from text: String) -> String {
        let pattern = "<think>[\\s\\S]*?</think>\\s*"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let fullRange = NSRange(text.startIndex..., in: text)
        let stripped = regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: "")
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Qwen3 chain-of-thought is disabled with /no_think in the system prompt.
    private func buildSystemContent() -> String {
        let isQwen3 = currentModelID.contains("Qwen3")
        let prefix = isQwen3 ? "/no_think\n" : ""
        return prefix + Self.systemPromptBody
    }

    private func buildUserContent(
        question: String,
        userBackground: String,
        jobContext: String
    ) -> String {
        """
        My background:
        \(userBackground)

        Job / company context:
        \(jobContext)

        Question: \(question)
        """
    }
}
