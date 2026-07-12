# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RaceKing is an AR racing game for iPhone, built with SwiftUI + RealityKit, with two modes: time attack (with a best-lap ghost car) and a 3-lap VS race against three AI karts. The circuit is anchored to the player's real floor via ARKit plane detection; in the iOS Simulator it falls back to a virtual camera over a fake grass ground so the game stays testable without a device. A single Xcode target (`RaceKing`, scheme `RaceKing`), iOS-only (iPhone locked to portrait; iPad allowed), with Mac/Vision 'Designed for iPad' opted out. There are no test targets and no package dependencies. UI copy is Japanese-first (HUD labels use racing English: LAP/BEST/START).

## Build Commands

Configurations: Debug, Release; Release is the default when unspecified.

```sh
# iOS Simulator (primary check)
xcodebuild -scheme RaceKing -destination 'generic/platform=iOS Simulator' -configuration Debug build

# iOS device (checks the AR-only code paths)
xcodebuild -scheme RaceKing -destination 'generic/platform=iOS' CODE_SIGNING_ALLOWED=NO build
```

Run in a simulator (needs an iOS 26.5+ runtime; older runtimes fail to install):

```sh
xcrun simctl boot <UDID> && xcrun simctl install <UDID> <path-to>/RaceKing.app
xcrun simctl launch <UDID> jp.hibiki.raceking.RaceKing
```

The project uses `PBXFileSystemSynchronizedRootGroup`: files added/removed under `RaceKing/` are picked up automatically, no pbxproj editing needed.

### Headless logic tests

There is no test target; game logic is verified by compiling the `Game/` sources into a CLI harness that bot-drives the car (pure pursuit toward a lookahead point on the centerline) and asserts laps complete, the ghost persists, and the VS race finishes with a valid rank:

```sh
swiftc -swift-version 5 -default-isolation MainActor -o botdrive main.swift \
  RaceKing/Game/*.swift
```

Run the harness with `HOME=<scratch-dir>` so the ghost file and UserDefaults don't pollute the real home directory.

`-default-isolation MainActor` matters — the Xcode target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and RealityKit `Entity`/`MeshResource` calls won't compile from nonisolated context without it. `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is also on: using `UIColor`/`NSColor` members requires explicitly importing UIKit/AppKit in that file. The app itself is iOS-only, but the files under `Game/` keep their `canImport(UIKit)/canImport(AppKit)` conditionals ON PURPOSE — the harness compiles them as a macOS CLI. Don't 'simplify' those to plain UIKit imports.

## Architecture

Everything is in real-world meters at miniature scale: the track footprint is ~1.9 × 1.4 m (fits a living-room floor), the car ~9 cm, top speed 0.65 m/s. The HUD "km/h" is a playful ×400 scaling of true speed. Best-lap times and the ghost file are keyed to `TrackLayout.totalLength`, so changing the track dimensions automatically invalidates stale records.

- `Game/RaceGame.swift` — the `@Observable` game controller and single source of truth. Owns the scene root entity, steps everything per frame (`update(deltaTime:)` is called from a `SceneEvents.Update` subscription in `ContentView`), and implements the race state machine (`ready → countdown → racing → finished`), ordered-checkpoint lap validation (blocks course cutting; shared with AI via `advanceCheckpoint`), lap timing, best-lap persistence (UserDefaults key `bestLapTime`), live ranking by accumulated track progress, soft kart separation (no hard collisions), and persisted settings (`ghostEnabled`, `tiltSteering`). It emits `GameEvent`s through `onEvent` — audio and haptics react to those; add new feedback there rather than inside game logic. Track limits are twofold: cars slow sharply when off the road (`TrackLayout.distanceFromCenterline`), and barrier walls at `TrackLayout.wallOffset` stop them entirely — collision is SDF-based (project the car back to `corridorLimit` along `lateralNormal`, scrub speed via `CarPhysics.hitWall`), not RealityKit physics. The visual guardrails in `EntityFactory` and the physics constraint both derive from `wallOffset`; keep them in sync through `TrackLayout`.
- `Game/CarPhysics.swift` — arcade physics struct shared by the player and AI: throttle/brake/drag integration, speed-scaled yaw, reverse gear, and the drift model. Tuning constants live here. Drift separates the nose from the travel direction via a slip angle; the slip growth is added to heading (not subtracted from the arc) so kicking the tail out never pushes the car wide at corner entry. Mini-turbo boost (2 tiers by drift duration) temporarily raises the speed cap.
- Drift lifecycle lives in `RaceGame.updateDrift`: a brake *tap* (< 0.22s) while steering at speed starts it (holding the brake falls back to real braking); straightening ends it and fires the boost; wall hits cancel it without reward. Effects (underglow by charge tier, boost flame, tire-smoke puffs, haptic pulses, squeal) are driven from `updateDriftEffects` + `GameEvent`s.
- `Game/TrackLayout.swift` — pure math for the rounded-rectangle circuit centerline: arc-length parametrization (`sample(at:)` returns position + tangent), a rounded-rect SDF for off-road detection, ordered checkpoint generation, `nearestS`/`progressDelta` for ranking. Change track shape/size here; everything else derives from it.
- `Game/GhostRecorder.swift` — records the player's pose each frame during time-attack laps; keeps the fastest lap (Codable plist under Application Support/RaceKing) and replays it via interpolation. The ghost hides once it finishes its lap.
- `Game/AIDriver.swift` — pure-pursuit AI karts (each with a different color and top speed via `defaultOpponents()`). They only exist in VS race mode; `RaceGame.placeCarsOnGrid()` adds/removes them.
- `Game/EntityFactory.swift` — builds visuals: road from overlapping flat box segments placed along the centerline, alternating red/white curbs, checkered start line, the kart (`makeCar(bodyColor:allowCustomModel:)`), and the fallback ground. Convention: models face +Z as "forward"; heading is yaw around +Y with `forward = (sin h, 0, cos h)`, and positive steering = right turn = heading decrease. The default cars are bundled USDZ models (`RaceKing/PlayerCar.usdz` = green GT for the player/ghost, `AICar1-3.usdz` = red/blue/white toys for the AI; originals live in `docs/`). Resolution order per slot: runtime-imported file (settings gear menu → Application Support, applied via `RaceGame.setCustomCarModel`/`setAICarModel`) > bundled USDZ > tinted procedural kart. "すべて標準の車に戻す" restores the bundled models. Models are normalized to ~9.5 cm, grounded at y = 0, and auto-oriented: `EntityFactory.detectForwardYaw` samples mesh vertices, takes the longer horizontal axis as the length, and assumes the lower end is the nose (cars carry cabin/wing height at the rear). When the guess is wrong the user flips it via the gear menu (`customCarFlipped`, persisted). When normalizing, multiply into the loaded root's scale rather than assigning — USD files carry their metersPerUnit conversion as a root scale. The three AI karts have their own import slots (`aiCarTemplates` / `AICar1-3.usdz`, applied via `AIDriver.applyModel`); a nil slot keeps that driver's tinted procedural kart. The effect attachments (`glowBlue`/`glowOrange`/`boostFlame` child entities, looked up by name from `RaceGame`) are added to every car regardless of source.
- `Audio/GameAudio.swift` — fully procedural audio (no assets): an `AVAudioSourceNode` synthesizes a speed-following saw-wave engine plus enveloped sine beeps. Synth state is behind an `OSAllocatedUnfairLock`; the render closure must stay `@Sendable` and capture no MainActor state. Uses the `.ambient` session category (respects the silent switch). `Audio/Haptics.swift` maps the same events to `UIFeedbackGenerator`s (iOS only).
- `Input/TiltSteering.swift` — CoreMotion tilt steering. Computes lateral bank from the gravity vector so it works while the phone points down at the floor in AR. Enabled via the gear menu; `ContentView` starts/stops it on setting change.
- `ContentView.swift` — device/simulator wiring. Device: `content.camera = .spatialTracking` + `game.installFloorAnchor()` (floor plane, 0.6 × 0.6 m+; the anchor sits on `anchorRoot`, and the course `root` moves freely inside it). Release hardening lives here and nearby: a camera-permission-denied overlay (`CameraDeniedView`, re-checked on scene activation), a "床を探しています" scanning state that replaces the ready menu until `RaceGame.isCourseAnchored` flips true (derived from `anchorRoot.isAnchored`; always true off-device), audio recovery observers in `GameAudio` (interruption/config-change/foreground → engine restart), a `PrivacyInfo.xcprivacy` (UserDefaults, CA92.1), and iPhone locked to portrait. Course placement is aim-based: `cameraRig` (an entity anchored to `.camera`) supplies the camera pose, a screen-center reticle shows the aim, and tap / drag casts that aim ray onto the floor via `moveCourse(alongRayFrom:direction:)` (ready phase only, clamped to ±2 m). Don't try `EntityTargetValue.convert`/`location3D` for placement — those APIs are visionOS-only; re-adding `AnchoringComponent` to re-place also doesn't work (it re-resolves to the same plane). "回転" spins `root.orientation` in 45° steps; all game logic lives in root-local space so both stay safe. Simulator: fallback ground + `PerspectiveCameraComponent` + `.realityViewCameraControls(.orbit)`. Any scene change must keep both branches working.
- `UI/GameOverlayView.swift`, `UI/ControlsView.swift` — HUD (lap/timer/best/position), mode picker, countdown/START/finish overlays, settings menu, and hold-to-press pedal buttons (`DragGesture(minimumDistance: 0)`, unavailable on tvOS — guarded with `#if !os(tvOS)`).

`NSCameraUsageDescription` lives in build settings (`INFOPLIST_KEY_NSCameraUsageDescription`), not an Info.plist file.
