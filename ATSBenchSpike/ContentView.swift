//
//  ContentView.swift
//  ATSBenchSpike
//

import SwiftUI

struct ContentView: View {

    @StateObject private var service = LLMService()

    // pickerSelection is local so the Picker binding doesn't mutate
    // service.selectedModel before selectModel() can compare old vs. new.
    @State private var pickerSelection: ModelEntry = LLMService.availableModels[0]
    @State private var userBackground = ""
    @State private var jobContext = ""
    @State private var question = "Why do you want to work at this company?"
    @State private var generationError: String?

    var body: some View {
        NavigationStack {
            currentStateView
                .navigationTitle("ATS Assist")
                .navigationBarTitleDisplayMode(.inline)
        }
        .task {
            // Auto-start on launch; Hub checks local cache before downloading.
            await service.downloadAndLoad()
        }
    }

    // MARK: — State routing

    @ViewBuilder
    private var currentStateView: some View {
        switch service.loadState {
        case .idle:
            idleView
        case .downloading(let progress):
            downloadingView(progress: progress)
        case .ready:
            formView
        case .failed(let message):
            failedView(message: message)
        }
    }

    // MARK: — Idle

    private var idleView: some View {
        VStack(spacing: 20) {
            ProgressView()
            Text("Preparing…")
                .foregroundStyle(.secondary)
        }
    }

    // MARK: — Downloading

    private func downloadingView(progress: Double) -> some View {
        let modelID = service.currentModelID
        let shortName = modelID.components(separatedBy: "/").last ?? modelID
        return VStack(spacing: 24) {
            Text("Downloading model")
                .font(.headline)
            Text(shortName)
                .font(.footnote)
                .foregroundStyle(.secondary)
            ProgressView(value: progress)
                .padding(.horizontal, 40)
            Text(String(format: "%.0f%%", progress * 100))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding()
    }

    // MARK: — Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 20) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            Text("Failed to load model")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Try Again") {
                Task { await service.retry() }
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
    }

    // MARK: — Main form

    private var formView: some View {
        Form {
            Section("Model") {
                Picker("Model", selection: $pickerSelection) {
                    ForEach(LLMService.availableModels) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: pickerSelection) { _, newModel in
                    Task { await service.selectModel(newModel) }
                }
                .disabled(service.isGenerating)
            }

            Section("Your Background") {
                TextEditor(text: $userBackground)
                    .frame(minHeight: 80)
            }

            Section("Job / Company Context") {
                TextEditor(text: $jobContext)
                    .frame(minHeight: 80)
            }

            Section("Application Question") {
                TextEditor(text: $question)
                    .frame(minHeight: 56)
            }

            Section {
                generateButton
            }

            if let error = generationError {
                Section {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                }
            }

            if let m = service.metrics {
                Section("Latency") {
                    metricsRow(label: "Load time", value: String(format: "%.2f s", m.loadTimeSeconds))
                    metricsRow(label: "Prompt", value: "\(m.promptTokens) tok · \(String(format: "%.1f", m.promptTokensPerSecond)) tok/s")
                    metricsRow(label: "Generation", value: "\(m.generationTokens) tok · \(String(format: "%.1f", m.tokensPerSecond)) tok/s")
                    metricsRow(label: "Wall time", value: String(format: "%.2f s", m.totalWallSeconds))
                    metricsRow(label: "MLX active", value: String(format: "%.0f MB", m.mlxActiveMB))
                    metricsRow(label: "Phys footprint", value: String(format: "%.0f MB", m.physicalFootprintMB))
                }
            }

            if !service.output.isEmpty {
                Section("Generated Draft") {
                    Text(service.output)
                        .textSelection(.enabled)
                        .font(.body)
                }
            }
        }
    }

    private var generateButton: some View {
        Button(action: runGeneration) {
            HStack {
                Spacer()
                if service.isGenerating {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Generating…")
                    }
                } else {
                    Text("Generate Draft")
                        .bold()
                }
                Spacer()
            }
        }
        .disabled(isGenerateDisabled)
    }

    private func metricsRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .monospacedDigit()
        }
        .font(.callout)
    }

    private var isGenerateDisabled: Bool {
        service.isGenerating
            || userBackground.trimmingCharacters(in: .whitespaces).isEmpty
            || jobContext.trimmingCharacters(in: .whitespaces).isEmpty
            || question.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: — Actions

    private func runGeneration() {
        generationError = nil
        Task {
            do {
                try await service.generate(
                    question: question,
                    userBackground: userBackground,
                    jobContext: jobContext
                )
            } catch {
                generationError = error.localizedDescription
            }
        }
    }
}

#Preview {
    ContentView()
}
