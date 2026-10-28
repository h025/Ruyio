# Ruyio

A free, open-source, native macOS toolbox made of plugins. The host provides plugin runtime, a command
palette, global shortcuts, Finder context menus, a menu bar item, permissions and plugin management;
tools come from plugins. V1 ships two removable default plugins: **Clipboard History** and **Finder Essentials**.

Platform: Apple Silicon (arm64), macOS 15 / 26 / 27. Languages: Simplified Chinese and English.

## Layout

| Path | Contents |
|---|---|
| `Packages/RuyioKit` | Swift package: `RuyioCore`, `RuyioProtocol` (manifest, IPC, UI schema, Finder wire), `RuyioPluginSDK`, `RuyioPersistence` (GRDB), `RuyioSourceTransport`, `RuyioHostKit` (registry, supervisor, router, brokers, installer, updates, markets), `RuyioUI` (schema renderer), and the two official plugin kits |
| `Apps/Ruyio` | AppKit + SwiftUI host app |
| `Extensions/FinderSync` | Finder Sync extension (snapshot reader, request writer) |
| `Plugins/*` | Plugin app shells and manifests; built, signed and embedded as `.ruyioplugin.zip` |
| `project.yml` | XcodeGen project definition |
| `Scripts/` | Build helpers |

## Build and run

```sh
brew install xcodegen
xcodegen generate
xcodebuild -project Ruyio.xcodeproj -scheme Ruyio -configuration Debug -derivedDataPath build/DerivedData build
open build/DerivedData/Build/Products/Debug/Ruyio.app
```

Builds are ad-hoc signed ("Sign to Run Locally"). Plugins run as separate sandboxed processes and talk to
the host over anonymous pipes; their UI is rendered by the host from a versioned schema.

For daily use, install with `Scripts/install-local.sh` (builds Release, or pass an existing `Ruyio.app`).
It re-signs the app with a local self-signed identity so Accessibility and other privacy grants survive
rebuilds, replaces `/Applications/Ruyio.app`, and leaves only that copy's Finder extension registered.
Copying an ad-hoc build over `/Applications/Ruyio.app` instead voids the grants: System Settings keeps
showing them on, but macOS no longer matches the app.

## Test

```sh
swift test --package-path Packages/RuyioKit
```

Tests include real-process integration (handshake, crash isolation, sandbox containment, cancellation),
storage (Chinese trigram search, quotas, secure deletion), the file broker, the zip extractor, the installer
and signature policy, transactional updates with rollback, the Finder channel and market resolution.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependencies and design references.
