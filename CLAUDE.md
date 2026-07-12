# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

RaceKing is an AR racing game (time attack) for iPhone, built with SwiftUI + RealityKit. The circuit is anchored to the player's real floor via ARKit plane detection; on macOS/simulator it falls back to a virtual camera over a fake grass ground so the game stays testable without a device. A single Xcode target (`RaceKing`, scheme `RaceKing`) builds for iOS, macOS, tvOS, and visionOS, but iPhone is the primary platform. There are no test targets and no package dependencies. UI copy is Japanese-first (HUD labels use racing English: LAP/BEST/START).

## Build Commands

Configurations: Debug, Release; Release is the default when unspecified.

```sh
# iOS Simulator (primary check)
xcodebuild -scheme RaceKing -destination 'generic/platform=iOS Simulator' -configuration Debug build

# macOS (secondary compile check for platform conditionals)
xcodebuild -scheme RaceKing -destination 'platform=macOS' build
```

Run in a simulator (needs an iOS 26.5+ runtime; older runtimes fail to install):

```sh
xcrun simctl boot <UDID> && xcrun simctl install <UDID> <path-to>/RaceKing.app
xcrun simctl launch <UDID> jp.hibiki.raceking.RaceKing
```

The project uses `PBXFileSystemSynchronizedRootGroup`: files added/removed under `RaceKing/` are picked up automatically, no pbxproj editing needed.

### Headless logic tests

There is no test target; game logic is verified by compiling the `Game/` sources into a CLI harness that bot-drives the car (pure pursuit toward a lookahead point on the centerline) and asserts laps complete:

```sh
swiftc -swift-version 5 -default-isolation MainActor -o botdrive main.swift \
  RaceKing/Game/TrackLayout.swift RaceKing/Game/RaceGame.swift RaceKing/Game/EntityFactory.swift
```

`-default-isolation MainActor` matters — the Xcode target sets `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`, and RealityKit `Entity`/`MeshResource` calls won't compile from nonisolated context without it. `SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY` is also on: using `UIColor`/`NSColor` members requires explicitly importing UIKit/AppKit in that file.

## Architecture

Everything is in real-world meters at miniature scale: the track footprint is ~1.2 × 0.9 m (fits a room floor), the car ~9 cm, top speed 0.65 m/s. The HUD "km/h" is a playful ×400 scaling of true speed.

- `Game/RaceGame.swift` — the `@Observable` game controller and single source of truth. Owns the scene root entity, runs arcade car physics per frame (`update(deltaTime:)` is called from a `SceneEvents.Update` subscription in `ContentView`), and implements the race state machine (`ready → countdown → racing`), ordered-checkpoint lap validation (blocks course cutting), lap timing, and best-lap persistence (UserDefaults key `bestLapTime`). SwiftUI controls write `steeringInput`/`throttleInput`/`brakeInput` directly; the HUD observes its published state. Cars slow sharply when off the road (checked via `TrackLayout.distanceFromCenterline`), which is the only "track limit" — there are no collision walls.
- `Game/TrackLayout.swift` — pure math for the rounded-rectangle circuit centerline: arc-length parametrization (`sample(at:)` returns position + tangent), a rounded-rect SDF for off-road detection, and ordered checkpoint generation. Change track shape/size here; everything else (mesh placement, grid position, checkpoints) derives from it.
- `Game/EntityFactory.swift` — builds visuals: road from overlapping flat box segments placed along the centerline, alternating red/white curbs, checkered start line, the kart, and the fallback ground. Convention: models face +Z as "forward"; heading is yaw around +Y with `forward = (sin h, 0, cos h)`, and positive steering = right turn = heading decrease.
- `ContentView.swift` — platform wiring. iOS device: `content.camera = .spatialTracking` + `AnchoringComponent(.plane(.horizontal, classification: .floor, minimumBounds: [0.6, 0.6]))` on `game.root`. macOS/simulator: fallback ground + `PerspectiveCameraComponent` + `.realityViewCameraControls(.orbit)`. Any scene change must keep both branches working (plus the visionOS branch, which gets neither).
- `UI/GameOverlayView.swift`, `UI/ControlsView.swift` — HUD (lap/timer/best), countdown/START overlays, and hold-to-press pedal buttons (`DragGesture(minimumDistance: 0)`, unavailable on tvOS — guarded with `#if !os(tvOS)`).

`NSCameraUsageDescription` lives in build settings (`INFOPLIST_KEY_NSCameraUsageDescription`), not an Info.plist file.
