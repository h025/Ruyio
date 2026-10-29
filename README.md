# Ruyio

A free, open-source, native macOS toolbox made of plugins. The host provides plugin runtime, a command
palette, global shortcuts, Finder context menus, a menu bar item, permissions and plugin management;
tools come from plugins. V1 ships two removable default plugins: **Clipboard History** and **Finder Essentials**.

Platform: Apple Silicon (arm64), macOS 14 / 15 / 26 / 27. Languages: Simplified Chinese and English.
Status: early 0.0.x releases; not feature-complete yet.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/h025/Ruyio/main/Scripts/install.sh | sh
```

The script downloads the latest [release](https://github.com/h025/Ruyio/releases), checks that it is signed
with Ruyio's release certificate (SHA-256 `7599d581e90fc58d44f395d3d5f6fc7df11709d33127fd8274dd0b76ee073a35`)
and installs it in `/Applications`. After that, Ruyio updates itself from General settings.

Ruyio is not notarized by Apple: the project does without the paid Developer Program. If you download the
zip from the release page instead, unzip it, move Ruyio to Applications, open it once, then click **Open
Anyway** in System Settings › Privacy & Security. Documentation is in the [wiki](https://github.com/h025/Ruyio/wiki).

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

## Development workflow

Work happens on branches in separate worktrees. `Scripts/check.sh` (all package tests plus a Release
build of one exact commit) gates every change, `Scripts/land.sh` fast-forwards `main` only to commits
that passed it, and `main` is published here with `Scripts/publish-code.sh`, which triggers CI. Pull
requests are welcome: CI runs on them, and maintainers land them through the same gate. Details are in
[`AGENTS.md`](AGENTS.md).

Releases are built and published by GitHub Actions when a commit on `main` raises the version. Without an
Apple Developer ID, the app is signed with a self-signed release certificate whose designated requirement
stays the same across versions, so privacy grants survive updates; the update archive is signed with an
EdDSA key in Sparkle's appcast format, and Ruyio installs an update only if both signatures match the
running copy.

## Test

```sh
swift test --package-path Packages/RuyioKit
```

Tests include real-process integration (handshake, crash isolation, sandbox containment, cancellation),
storage (Chinese trigram search, quotas, secure deletion), the file broker, the zip extractor, the installer
and signature policy, transactional updates with rollback, the Finder channel and market resolution.

## License

MIT. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for dependencies and design references.
