# Project Noah: roadmap and project brief

> Context document for Claude Code. The goal here is for you (the model) to
> understand what we are building and why. Architecture is not finalized: several
> directions are gated on experiments ("spikes") that have not been run yet.
> Anything not yet decided is marked **unclear as of now**.

## What this is

Project Noah is a personal iOS tool that autofills job applications from the
phone. It fills the normal application fields automatically and, for free-form
questions (for example "why this company?"), it reuses my own past answers when
it can and drafts an answer with a small on-device language model only when the
question is genuinely new. Everything runs on-device. It is built for one user
(me) on iOS 26, not as a product for now.

## The problem it solves

Desktop autofill tools (Jobright, Simplify, and similar) are browser extensions
and do not work on mobile, because Chrome on Android has no extensions and the
iOS equivalents were never built. So when I see a job on my phone I cannot apply
properly and have to wait until I am back at a desktop. Noah is the on-device
mobile autofill that does not exist yet, built for my own use.

## Constraints and assumptions

- Single user, personal use. No accounts, no multi-tenant, no server backend.
- iOS 26, iPhone only. macOS and Android are out of scope.
- On-device only. Models run locally. The tool should ideally work offline and
  keep my data on the device.
- The free-form generator should never auto-submit a generic answer. For
  competitive roles, generic machine text hurts. Generated answers are drafts I
  review, not silent submissions.

## Core design idea: three kinds of fields

The entire system is organized around the fact that a job application form has
three kinds of fields, with very different costs. This split is the most
important thing to understand.

1. **Deterministic fields** (name, email, phone, work history, dates, work
   authorization). No model needed. Filled instantly from a stored profile.
   This is the bulk of any application and solves the core problem on its own.
2. **Repeat free-form questions.** Questions that I have answered before, just
   phrased differently. Matched against my own past answers using a small
   on-device embedding model and reused or lightly adapted. No generation needed.
3. **Novel free-form questions.** Genuinely new questions with no good match.
   Drafted by a small on-device generator (~1B parameters). This is the only
   expensive path and it should be rare, especially after the answer cache fills
   up over the first few weeks of real use.

The profile in (1) comes from a one-time step: my resume is parsed once by the
language model into structured fields, which I confirm and correct, after which
that confirmed profile is the canonical source and is never re-extracted.

## Architecture: undecided, three candidates

**Unclear as of now.** The architecture is not chosen. It depends on the spike
results below. Three candidates are on the table.

**Option A: Safari web extension + companion app.**
A Safari web extension reads and fills fields on ATS sites. A separate companion
app exists for one reason only: to run the language model, which is too large to
run inside the extension. They communicate through an App Group shared container.
Cost: generating a novel answer requires bringing the companion app to the
foreground (the "app switch"), because iOS will not run a heavy model in the
background. The switch is batched (once per application, not per field) and fades
as the cache fills, but it never fully disappears.

**Option B: single app with an embedded web view (currently the front-runner).**
One app renders job pages inside a WKWebView, injects JavaScript to read and fill
fields, and runs the model in the same foreground process. No App Group, no
extension memory limit, no app switch ever. Cost: I browse jobs inside my own app
instead of Safari, and an embedded web view can hit compatibility problems with
ATS logins and bot protection (Workday especially).

**Option C: everything in-browser via WebGPU (the architecture-collapsing case).**
iOS 26 Safari supports WebGPU, so it may be possible to run the small generator
directly inside the extension's web context (via WebLLM or Transformers.js). If a
~1B model runs reliably there, the companion app disappears entirely and Noah
becomes a single Safari extension with no switch. Expectation: embeddings will run
in-browser fine; a 1B+ generator is the risk, because mobile WebKit memory is
tight and the extension context is tighter than a normal tab. This is the first
thing to test, because a positive result removes most of the rest of the work.

## Decision gates: spikes to run before committing

These experiments decide the architecture. Run them roughly in this order;
results cascade (a good result early can cancel later work). Each should be done
on a real iPhone running iOS 26, not the simulator, because the memory and
web-view behavior only show up on device.

1. **Confirm nothing already solves this.** Verify no existing iOS app or Safari
   extension already does ATS autofill well. Cheapest possible outcome: do not
   build.
2. **WebGPU in-extension generation (the switch-killer).** Try running a small
   (~1B) quantized generator inside a real Safari web extension's web context via
   WebLLM or Transformers.js. If it works, go with Option C.
3. **WKWebView ATS compatibility.** Load a real Workday and a real Greenhouse
   application inside a bare WKWebView, log in, and fill one field with injected
   JS. If auth and form interaction survive, Option B is viable. If Workday fights
   the web view, fall back to Option A.
4. **Deterministic field read and fill.** Confirm reliable field selection and
   filling on Workday (dynamic rendering), Greenhouse (React), and Lever with
   injected JS. This is the unglamorous core where most of the real engineering
   risk lives.
5. **Extension handler memory ceiling.** Measure how much memory the Safari
   extension's native handler can use before iOS kills it. Determines whether
   embeddings can live in the handler or must live in the app. Only relevant to
   Option A.
6. ~~**Companion-app generation benchmark.** Run a 1 to 3B model at 4-bit via MLX or
   llama.cpp in a normal app target (with the increased-memory entitlement) and
   measure tokens per second and on-disk size. Only relevant to Option A.~~ **DONE** — Qwen3 1.7B and Llama 3.2 3B running via MLX at 4-bit in `ATSBenchSpike`. Metrics captured: cold load time, tok/s (prompt + decode), time-to-first-token, MLX active MB, physical footprint MB, on-disk size.
7. **End-to-end round-trip latency.** If on Option A, measure the full loop
   including the foreground switch, because that is the latency actually felt.

**Prep item (not code):** pull from my own application history which ATS
platforms dominate my funnel, so the field-mapping engine targets the two or three
that matter instead of all of them.

## Hard platform constraints that shaped this design

- **iOS apps cannot control other apps.** There is no Android-style accessibility
  automation or desktop UI scripting. The only place Noah gets full read-and-fill
  control of a page is a web view it owns. This is the main reason Option B exists.
- **Memory.** A real generator does not fit in the Safari web context or the
  extension handler reliably; those are heavily memory-constrained. Only a
  foreground app (with the increased-memory entitlement) has a dependable budget
  for a 1B+ model. This is the main reason the companion app exists in Option A.
- **No on-demand background compute.** iOS will not wake a backgrounded app to run
  a model on demand, so on-device generation requires a foreground process. This is
  the origin of the "app switch" cost in Option A.

## Model stack

- **Embedding model** (small, tens of MB, for example a MiniLM-class model): embeds
  incoming questions and matches them against my stored past answers. Runs
  in-browser via WebGPU or in the app, depending on architecture.
- **Generator** (~1B, 4-bit quantized): drafts answers to novel free-form
  questions only. Runs via WebLLM / Transformers.js in-browser (Option C) or via
  MLX / llama.cpp in the companion or single app (Options A and B).
- **One-time resume extraction:** the generator parses my resume into a structured
  profile once, which I confirm. Not run again after that.

## Build phases (after the architecture is chosen)

- **Phase 0:** run the spikes, pick the architecture.
- **Phase 1:** deterministic autofill only, no model, on the two or three ATS
  platforms that matter. This alone solves the core problem and is worth shipping
  to myself first.
- **Phase 2:** add the embedding-based question matcher and the answer cache that
  stores and reuses my past free-form answers.
- **Phase 3:** add the generator for novel questions, as review-first drafts.
- **Phase 4:** polish the fill UX, expand ATS coverage as needed.

The sequencing matters: if Phase 1 alone removes the pain, that is real signal that
the model layer is a credibility and convenience addition, not the core need, and
it can be built deliberately rather than rushed.

## Explicit unknowns (unclear as of now)

- Which architecture (A, B, or C). Gated on spikes 2 and 3.
- Whether a 1B generator runs reliably in the iOS Safari web context (spike 2).
- Whether WKWebView can handle real ATS auth and bot protection (spike 3).
- The exact extension-handler memory ceiling on device (spike 5).
- Generation latency and model size on my specific iPhone (spike 6).
- Final model choices for both embeddings and generation.
- Exactly how answers are stored and matched (similarity threshold, adaptation
  logic for company-specific answers).

## Out of scope / do not build

- Mass auto-apply or bulk submission. Noah assists single, deliberate applications.
- Multi-user, accounts, or any server backend.
- Android, macOS, or non-iOS targets.
- Controlling or automating other apps' UIs. Not possible on iOS; do not attempt.
- Supporting every ATS platform. Target only the few that dominate my own funnel.