# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

ATSBenchSpike is a SwiftUI iOS/macOS app created as a spike (proof-of-concept/benchmarking project). It was scaffolded with Xcode's default SwiftUI template and is in early development.

## Build & Run

This project must be built and run through Xcode or `xcodebuild`. There is no package manager (no SPM Package.swift, no Podfile, no Cartfile).

```bash
# Build from the command line (simulator)
xcodebuild -project ATSBenchSpike.xcodeproj \
           -scheme ATSBenchSpike \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           build

# Run tests (once tests exist)
xcodebuild -project ATSBenchSpike.xcodeproj \
           -scheme ATSBenchSpike \
           -destination 'platform=iOS Simulator,name=iPhone 16' \
           test
```

For interactive development, open `ATSBenchSpike.xcodeproj` in Xcode and use Cmd+R to run.

## Architecture

Single-target SwiftUI app with the standard entry-point pattern:

- `ATSBenchSpikeApp.swift` — `@main` entry point, creates the root `WindowGroup` with `ContentView`
- `ContentView.swift` — root view; currently the Xcode default placeholder
- `Assets.xcassets` — app icon and accent color assets

There are no tests, no additional targets, and no external dependencies at this stage.

## Git Commits

Never include a `Co-Authored-By: Claude` trailer (or any Anthropic/Claude attribution) in commit messages for this repository.
