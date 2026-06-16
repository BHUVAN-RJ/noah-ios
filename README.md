# Noah — On-Device iOS Job Application Autofill

> Personal iOS tool that autofills job applications from the phone. Everything runs on-device. Built for one user, not a product.

---

## The Problem

Desktop autofill tools (Jobright, Simplify, etc.) are browser extensions — they don't work on mobile. Chrome on iOS has no extensions, and no equivalent was ever built for Safari. When you see a job on your phone, you can't apply properly and have to wait until you're back at a desktop.

Noah is the missing mobile autofill, built for personal use on iOS 26.

---

## How It Works: Three Kinds of Fields

Every job application form has three kinds of fields with very different costs:

```
┌─────────────────────────────────────────────────────────────────┐
│                    Job Application Form                         │
├──────────────────┬──────────────────────┬───────────────────────┤
│  DETERMINISTIC   │   REPEAT FREE-FORM   │   NOVEL FREE-FORM     │
│                  │                      │                       │
│  Name, email,    │  "Tell us about      │  "Why specifically    │
│  phone, work     │  yourself" — asked   │  this company?" —     │
│  history, dates, │  before, phrased     │  genuinely new,       │
│  work auth       │  differently         │  no past match        │
│                  │                      │                       │
│  → Stored        │  → Embedding model   │  → ~1B generator      │
│    profile       │    matches past      │    drafts answer      │
│    (no model)    │    answer & reuses   │    for review         │
│                  │                      │                       │
│  Instant. Free.  │  Fast. Cached.       │  Slow. Rare.          │
│  Bulk of forms.  │  Fades in over time. │  Review before send.  │
└──────────────────┴──────────────────────┴───────────────────────┘
```

The generator is only ever the last resort. As the answer cache fills up over real use, novel questions become rare.

---

## Architecture: Three Candidates

Architecture is not yet chosen — it depends on spike results. The three options are:

### Option A — Safari Extension + Companion App

```
┌──────────────────────────────────────────────────────────────────┐
│  Safari (foreground)                                             │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  ATS Page (Workday / Greenhouse / Lever)                   │  │
│  │                                                            │  │
│  │  ┌─────────────────────────────────────────────────────┐  │  │
│  │  │  Safari Web Extension                               │  │  │
│  │  │  • reads field values via content script            │  │  │
│  │  │  • injects deterministic fills instantly            │  │  │
│  │  │  • for free-form: asks native handler               │  │  │
│  │  └───────────────────┬─────────────────────────────────┘  │  │
│  └──────────────────────│────────────────────────────────────┘  │
│                         │ NSExtensionRequestHandling             │
│  ┌──────────────────────▼──────────────────────────────────┐    │
│  │  Extension Native Handler (memory-constrained)          │    │
│  │  • embedding model (if memory allows)                   │    │
│  │  • routes novel questions → Companion App via AppGroup  │    │
│  └──────────────────────┬────────────────────────────────────   │
└─────────────────────────│────────────────────────────────────── ┘
                          │ App Group shared container
┌─────────────────────────▼────────────────────────────────────────┐
│  Noah Companion App (must be brought to foreground)              │
│  • ~1–3B generator via MLX / llama.cpp                           │
│  • increased-memory entitlement                                  │
│  • writes draft back to shared container                         │
└──────────────────────────────────────────────────────────────────┘

Cost: one app switch per application (not per field). Fades as cache fills.
```

### Option B — Single App + Embedded WKWebView *(current front-runner)*

```
┌──────────────────────────────────────────────────────────────────┐
│  Noah App (foreground, one process)                              │
│                                                                  │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │  WKWebView                                               │   │
│  │  • renders ATS job page (Workday / Greenhouse / Lever)   │   │
│  │  • JS injected to read and fill fields                   │   │
│  └──────────────────────────┬───────────────────────────────┘   │
│                             │ WKScriptMessageHandler             │
│  ┌──────────────────────────▼───────────────────────────────┐   │
│  │  Swift Layer                                             │   │
│  │  • profile store (deterministic fills)                   │   │
│  │  • embedding model + answer cache (repeat questions)     │   │
│  │  • ~1–3B generator via MLX (novel questions)             │   │
│  └──────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────┘

Cost: user browses jobs inside Noah, not Safari.
Risk: WKWebView compatibility with ATS logins and bot protection.
```

### Option C — Everything In-Browser via WebGPU *(architecture-collapsing case)*

```
┌──────────────────────────────────────────────────────────────────┐
│  Safari (foreground)                                             │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  ATS Page                                                  │  │
│  │  ┌──────────────────────────────────────────────────────┐  │  │
│  │  │  Safari Web Extension                                │  │  │
│  │  │  • reads + fills fields via content script           │  │  │
│  │  │  • embedding model via WebGPU (Transformers.js)      │  │  │
│  │  │  • ~1B generator via WebGPU (WebLLM)                 │  │  │
│  │  │    ↑ this is the open question (spike 2)             │  │  │
│  │  └──────────────────────────────────────────────────────┘  │  │
│  └────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────┘

No companion app. No app switch. Ever.
Risk: mobile WebKit memory is tight; a 1B+ model may not fit in the extension context.
```

---

## Model Stack

```
┌─────────────────────────────────────────────────────────────────┐
│                         Model Stack                             │
├───────────────────────────┬─────────────────────────────────────┤
│  Embedding model          │  Generator                          │
│  (MiniLM-class, ~tens MB) │  (~1B params, 4-bit quantized)      │
│                           │                                     │
│  • embeds incoming        │  • drafts answers to novel          │
│    question               │    free-form questions only         │
│  • cosine similarity vs   │  • output is a review-first draft   │
│    stored past answers    │    — never auto-submitted           │
│  • runs in-browser        │  • runs via WebLLM/Transformers.js  │
│    (Option C) or in-app   │    (Option C) or MLX/llama.cpp      │
│    (Options A & B)        │    (Options A & B)                  │
└───────────────────────────┴─────────────────────────────────────┘

One-time setup: resume parsed into structured profile → confirmed by user
→ never re-extracted. Profile drives all deterministic fills.
```

---

## Decision Gates (Spikes)

Run roughly in order — a positive result early can cancel later work. All spikes should be run on a **real iPhone running iOS 26**, not the simulator.

| # | Spike | Status |
|---|-------|--------|
| 1 | Confirm no existing tool already solves this | pending |
| 2 | WebGPU in-extension generation — run ~1B model via WebLLM in Safari extension context | pending |
| 3 | WKWebView ATS compatibility — load Workday + Greenhouse, log in, fill a field with JS | pending |
| 4 | Deterministic field read and fill — reliable field selection on Workday, Greenhouse, Lever | pending |
| 5 | Extension handler memory ceiling — how much can the native handler use before iOS kills it | pending |
| 6 | **Companion-app generation benchmark** — 1–3B model at 4-bit via MLX, measure tok/s and on-disk size | ✅ done |
| 7 | End-to-end round-trip latency (Option A only) — full loop including foreground switch | pending |

### Spike 6 Results (this repo)

Models tested via MLX Swift at 4-bit quantization:

| Model | On-disk | Load time | Decode | Notes |
|-------|---------|-----------|--------|-------|
| Qwen3 1.7B 4-bit | ~1 GB | measured | measured | strips `<think>` blocks |
| Llama 3.2 3B 4-bit | ~1.7 GB | measured | measured | |

Metrics captured per run: cold load time · time-to-first-token · prompt tok/s · decode tok/s · MLX active MB · physical footprint MB · on-disk size MB.

---

## Build Phases (after architecture is chosen)

```
Phase 0  →  Run spikes, pick architecture           ← we are here
Phase 1  →  Deterministic autofill only, no model,
            on the 2–3 ATS platforms that matter
Phase 2  →  Embedding-based question matcher +
            answer cache (reuse past answers)
Phase 3  →  Generator for novel questions,
            review-first drafts
Phase 4  →  Polish fill UX, expand ATS coverage
```

Phase 1 alone removes the core pain and is worth shipping to yourself first. If it does, the model layer is a convenience addition — not the core need.

---

## Build & Run (this spike)

This project requires Xcode and the MLX Swift packages. There is no SPM Package.swift at the repo root — dependencies are managed inside the Xcode project.

```bash
# Open in Xcode
open ATSBenchSpike.xcodeproj

# Build for simulator via CLI (no MLX GPU — functional only)
xcodebuild -project ATSBenchSpike.xcodeproj \
           -scheme ATSBenchSpike \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           build
```

For real benchmark numbers, run on a physical iPhone via Xcode (Cmd+R). The simulator does not have a Metal GPU and will not reflect real memory or throughput.

---

## Constraints

- **Single user, personal use.** No accounts, no server backend.
- **iOS 26, iPhone only.** macOS and Android are out of scope.
- **On-device only.** Works offline. Data stays on device.
- **No auto-submit.** Generated answers are drafts you review — generic machine text hurts for competitive roles.
- **No mass apply.** Noah assists single, deliberate applications.

---

## Out of Scope

- Mass auto-apply or bulk submission
- Multi-user, accounts, or any server backend
- Android, macOS, or non-iOS targets
- Controlling or automating other apps' UIs (not possible on iOS)
- Supporting every ATS platform (target only the few that dominate your funnel)
