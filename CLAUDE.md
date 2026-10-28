# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is Trio

Trio is an open-source automated insulin delivery (AID) system for iOS, built on the OpenAPS algorithm (via `trio-oref`, a Trio-specific fork). It uses LoopKit for pump/CGM integration and Nightscout for remote monitoring. The app targets people with diabetes who want a highly configurable AID system.

## Building

Trio requires Xcode. Open the workspace with `xed .`, or compile from the command line (no simulator or device needed):

```sh
xcodebuild build -workspace Trio.xcworkspace -scheme Trio -destination 'generic/platform=iOS Simulator'
```

Check the log for `error:` lines rather than trusting `BUILD SUCCEEDED` alone: Xcode can skip recompiling changes in synchronized folders.

`Config.xcconfig` includes `ConfigOverride.xcconfig` from `../../`, `../` and the repo root, in that order, and later files win. All three are git-ignored. The Apple Developer Team ID (`DEVELOPER_TEAM`) goes in one of them.

Submodules must be initialized:
```sh
git submodule update --init --recursive
```

## Code Formatting

SwiftFormat is the only formatter. Run it via the build tool script (requires `SRCROOT` to be set to the repo root):

```sh
SRCROOT=$(pwd) ./scripts/swiftformat.sh
```

Key formatting rules: 4-space indent, 130 max line width, sorted imports, `--self remove`. The script excludes all submodule directories (LoopKit, LibreTransmitter, CGMBLEKit, etc.) — never run SwiftFormat on those.

## Tests

Tests use Swift Testing (`import Testing`) and XCTest. Run via Xcode (`Cmd+U`) or `xcodebuild`:

```sh
# Run all tests
xcodebuild test -workspace Trio.xcworkspace -scheme Trio -destination 'platform=iOS Simulator,name=iPhone 16'

# Run a specific test file (example)
xcodebuild test -workspace Trio.xcworkspace -scheme Trio -destination 'platform=iOS Simulator,name=iPhone 16' -only-testing:TrioTests/GlucoseStorageTests
```

Core Data tests use an in-memory store initialized via `CoreDataStack.createForTests()` and a `TestAssembly` that overrides the storage layer.

## Architecture Overview

### Dependency Injection (Swinject)

All services are registered in `Trio/Sources/Assemblies/` and resolved via a global `TrioApp.resolver`. The six assemblies are: `StorageAssembly`, `ServiceAssembly`, `APSAssembly`, `NetworkAssembly`, `UIAssembly`, `SecurityAssembly`.

Use the `@Injected()` property wrapper (from `Trio/Sources/Helpers/PropertyWrappers/`) to resolve dependencies. Classes conforming to `Injectable` can call `injectServices(resolver)` to trigger resolution. Every protocol has a `Base`-prefixed concrete implementation (e.g., `APSManager` → `BaseAPSManager`).

### Module Pattern (MVVM-like)

Each screen lives in `Trio/Sources/Modules/<ModuleName>/` and follows a fixed structure:
- `<Name>DataFlow.swift` — defines the `Provider` protocol (data access interface) and `Config` namespace
- `<Name>StateModel.swift` — `@Observable final class StateModel: BaseStateModel<Provider>` — business logic, state, Combine subscriptions
- `<Name>Provider.swift` — `BaseProvider` subclass implementing the Provider protocol
- `View/` — SwiftUI views conforming to `BaseView`

`BaseStateModel` (in `Modules/Base/`) wires up the resolver, instantiates the Provider, and calls `subscribe()`. Views call `configureView()` on appear to trigger this initialization. Navigation is driven by the `Router` using the `Screen` enum (`Trio/Sources/Router/Screen.swift`).

### APS / Algorithm Layer

`Trio/Sources/APS/` is the algorithmic core:

- **`APSManager`** — orchestrates the dosing loop (`determineBasal()`, `enactBolus()`, `enactTempBasal()`). The loop runs every 3 minutes (`Config.loopInterval`).
- **`DeviceDataManager`** — manages pump and CGM plugin lifecycle via LoopKit.
- **`OpenAPS`** (`APS/OpenAPS/OpenAPS.swift`) — runs the **JavaScript** oref algorithm via `JavaScriptWorker` (JavaScriptCore). Bundled JS lives in `javascript/` in the app bundle, sourced from the `trio-oref` submodule.
- **`OpenAPSSwift`** (`APS/OpenAPSSwift/`) — a **Swift port** of the same oref algorithm, currently running in parallel shadow mode. The Swift implementation computes results, compares them to the JS output, and logs any differences. It is not yet used for actual dosing decisions. The port covers `makeProfile`, `iob`, `meal`, `autosens`, and `determineBasal`.
- **`Storage/`** (`APS/Storage/`) — thin CoreData-backed stores for CGM readings, boluses, carbs, determinations, temp targets, overrides, TDD, and alerts.

### Data Persistence (Two-Layer)

**CoreData** (`Model/`) — primary persistence. `CoreDataStack.shared` holds `TrioCoreDataPersistentContainer`. Entity classes are in `Model/Classes+Properties/` (NSManagedObject subclasses). Key entities: `GlucoseStored`, `BolusStored`, `CarbEntryStored`, `OrefDetermination`, `Forecast`, `OverrideStored`.

**FileStorage** — legacy JSON file storage in the app's Documents directory, used for algorithm inputs/outputs and settings. Models conforming to the `JSON` protocol (Codable + `@dynamicMemberLookup`) are serialized via `Disk` library. `BaseFileStorage` serializes access through a serial `DispatchQueue`.

### Settings

`SettingsManager` (`Services/SettingsManager/`) holds two main structs: `TrioSettings` (app-level UI/behaviour settings) and `Preferences` (OpenAPS algorithm preferences). Both are persisted as JSON files. Changes broadcast to `SettingsObserver`/`PreferencesObserver` subscribers via the `Broadcaster` service.

### Logging

Use the global free functions `debug`, `info`, `warning`, `error` and `fault`, e.g. `warning(.storage, "Saving carbs failed", error: error)`. Categories are by subject, in `Logger.Category` (`Trio/Sources/Logger/Logger.swift`): `.loop`, `.algorithm`, `.pump`, `.cgm`, `.bolus`, `.treatments`, `.nightscout`, `.tidepool`, `.remote`, `.healthKit`, `.alerts`, `.watch`, `.liveActivity`, `.storage`, `.settings`, `.telemetry`, `.ui`, `.lifecycle`. The old categories (`.default`, `.service`, `.apsManager`, `.coreData`, …) were removed in Oct 2026. Write plain-language messages with no `[TypeName]` prefix or emoji; the Logging section of `CONTRIBUTING.md` has the house style. The watch app logs through `WatchLogger.shared.debug(.connectivity, …)` and friends.

### External Integrations

Pump and CGM drivers are git submodules (`LoopKit`, `OmnipodKit`, `MinimedKit`, `DanaKit`, `MedtrumKit`, `LibreTransmitter`, `CGMBLEKit`, `G7SensorKit`, `RileyLinkKit`, `dexcom-share-client-swift`, `TidepoolService`). Never modify these submodules directly.

Remote monitoring is via Nightscout (`Services/Network/Nightscout/`) and optionally Tidepool (`Services/Network/TidepoolManager.swift`).

### Localization

All user-facing strings must use `String(localized:)`. English strings are the source; other languages are managed via [Crowdin](https://crowdin.triodocs.org/) and must not be committed manually.

## Contribution Guidelines

- Branch from `dev`. Use `fix/`, `feature/`, or `refactor/` prefixes.
- Keep PRs small and focused. Explain what and why in the PR description.
- Do not submit AI-generated pull requests; contributions must be fully understood and intentionally designed by the author.
- Run SwiftFormat before committing. Avoid unrelated formatting changes.
- Do not modify files in submodule directories.

## This fork (gonkowonko/Trio)

Local `dev` carries personal commits on top of `nightscout/Trio` `dev`.

- Remotes: `upstream` = nightscout/Trio, fetch only (push URL `DISABLED`). Never push or open PRs there. `origin` = the gonkowonko/Trio fork; `dev` goes there only as a fast-forward after a clean build.
- `Config.xcconfig` commits `BUNDLE_IDENTIFIER = …trio2` for the fork's TestFlight build. Keep that line; local Xcode builds get `…trio` from the ignored `../ConfigOverride.xcconfig`.
- Local-only files that upstream doesn't have, so they never conflict: `Trio/Sources/Modules/Home/View/HomeRootView+HeaderPills.swift` (header pills), `Trio/Sources/Modules/Home/View/Header/SensorLifecycle/DeviceLanesView.swift` (device lanes) and `LiveActivity/Views/Custom/` (Custom Live Activity). Put local UI work in files like these rather than in upstream-shared ones.
- Files that diverge locally and conflict on merges: `GlassChrome.swift`, `HomeRootView.swift`, `HomeLayout.swift`, `LiveActivityManager.swift` (`LA-COALESCE`), and `HomeStateModel.resolveSensorExpiresAt` (delegates to `SensorExpiryResolver`). Mark local edits in upstream files with `// LOCAL:` or a stream tag (e.g. `LA-COALESCE`).
- New files under `Trio/Sources` need hand-written `project.pbxproj` entries; only `LiveActivity/Views` and `Preview Content` are synchronized groups.
- Update from upstream with the `/trio-update-from-dev` skill.
