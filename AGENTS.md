# Repository Guidelines

## Project Structure & Module Organization

`RaceKing/` contains the single iOS app target. `RaceKingApp.swift` starts the app, while `ContentView.swift` connects SwiftUI, RealityKit, AR placement, and the simulator fallback. Gameplay and track logic live in `RaceKing/Game/`; controls and overlays in `RaceKing/UI/`; audio and haptics in `RaceKing/Audio/`; and tilt input in `RaceKing/Input/`. App icons and colors belong in `Assets.xcassets`, bundled cars are the root-level `.usdz` files under `RaceKing/`, and source models plus the privacy policy live in `docs/`. The synchronized Xcode group automatically discovers files added under `RaceKing/`; do not edit `project.pbxproj` merely to register a file.

## Build, Test, and Development Commands

- `open RaceKing.xcodeproj` opens the project for local development with the `RaceKing` scheme.
- `xcodebuild -scheme RaceKing -destination 'generic/platform=iOS Simulator' -configuration Debug build` performs the primary compile check.
- `xcodebuild -scheme RaceKing -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build` also compiles device-only AR paths without requiring signing.

Use an iOS 26.0-or-newer SDK/runtime. There are no package dependencies or dedicated test targets.

## Coding Style & Naming Conventions

Follow existing Swift style: four-space indentation, one primary type per file, `UpperCamelCase` for types, and `lowerCamelCase` for properties and functions. Group larger types with `// MARK:` and document non-obvious gameplay rules with concise `///` comments. Keep game-state mutations on the main actor and preserve the conditional UIKit/AppKit imports in `Game/`, which allow headless logic compilation. UI copy is Japanese-first. No formatter or linter is configured, so use Xcode formatting and keep diffs focused.

## Testing Guidelines

Because the repository has no XCTest suite or coverage threshold, every change must at least pass both build commands above. Exercise time attack, VS race, pause/reset flows, and virtual-camera play in the simulator. Test AR floor placement, camera permission handling, tilt steering, audio, and haptics on a physical iPhone when those paths change. If adding a test target, name files `TypeNameTests.swift` and favor deterministic tests for `CarPhysics`, `TrackLayout`, AI progress, and lap validation.

## Commit & Pull Request Guidelines

Recent commits use short, single-purpose Japanese summaries without Conventional Commit prefixes, for example `アプリアイコンを刷新`. Match that style and avoid bundling unrelated changes. Pull requests should explain the user-visible behavior, list simulator/device verification, link the relevant issue, and include screenshots or a short recording for UI, camera, or AR changes. Call out new assets, persisted-data changes, permissions, or updates to `PrivacyInfo.xcprivacy` explicitly.
