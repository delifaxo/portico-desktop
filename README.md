# Portico Desktop

Portico is a native macOS application for managing and launching Windows games through separately installed Wine environments. It includes a SwiftUI game library, per-game launch settings, Windows Steam integration, runtime setup, diagnostics, logs, and optional cooling/FPS controls.

This repository contains the **desktop source code**. Apple Game Porting Toolkit, D3DMetal, Rosetta, Wine, GStreamer, CrossOver, Steam, games, user data, and iPad experiments are **not included**. See [Repository contents and sharing](docs/SHARING.md).

## Build from a clean clone

Requirements: macOS 14 or later, Swift 6 with Xcode Command Line Tools, Python 3, and Clang plus `lld-link` for the two small Windows helpers. Apple Silicon is the primary target. Set `PORTICO_CLANG` / `PORTICO_LLD_LINK` if the compiler or linker is outside the detected LLVM/Rust toolchain paths.

```sh
git clone https://github.com/delifaxo/portico-desktop.git
cd portico-desktop
./scripts/build-assets.sh
swift test
./scripts/build-app.sh --without-runtime
open dist/Portico.app
```

`build-assets.sh` compiles Portico's own diagnostic and Steam compatibility launcher from the C sources in this repository. It does not download third-party executables. The app build also generates these helpers when they are missing. Generated `.exe` files stay outside Git.

`--without-runtime` builds the slim developer app. Install or connect Wine through the app before creating a Windows environment. DX12 requires a compatible external runtime obtained separately under its applicable terms; connecting one does not copy it into the repository. Rosetta may be required for x86_64 Wine on Apple Silicon.

For a local app with an embedded Wine/GStreamer runtime, follow [embedded runtime preparation](docs/EMBEDDED_RUNTIME.md) before running `./scripts/build-app.sh` without the slim flag. That workflow uses local inputs; no runtime is distributed in this repository. Development builds use local ad-hoc signing.

## Usage

1. Prepare or connect a Wine runtime.
2. Create a separate environment for the game or Windows Steam client.
3. Run the game's installer, or select an already installed executable and configure its environment and launch settings.
4. Launch from the library and inspect the environment log when needed.

Steam sign-in and game downloads happen in the Windows Steam client. Compatibility depends on the game, runtime, graphics backend, and host Mac. A successful build or unit test does not establish game compatibility.

## Documentation

- [First setup (English)](docs/GETTING_STARTED.en.md)
- [First setup (Ukrainian)](docs/GETTING_STARTED.uk.md)
- [Already installed games](docs/EXISTING_GAMES.md)
- [Engine and game compatibility](docs/COMPATIBILITY.md)
- [Steam compatibility](docs/STEAM_COMPATIBILITY.md)
- [External DirectX 12 runtime](docs/DIRECTX12.md)
- [Local WineForge runtime](docs/WINEFORGE_LOCAL.md)
- [Cooling and FPS](docs/COOLING_AND_FPS.md)
- [Manual testing](docs/MANUAL_TESTING.md)
- [App Store research and remaining work](docs/APP_STORE.md)

Some technical documents contain dated development results. They describe those local checks, not a current release certification.

## Development

`Package.swift` defines the macOS app, `PorticoCore`, `PorticoCoolingHelper`, and the core test suite. `Sources/CoolingSMC` contains the native cooling interface. Its recovery test uses simulated hardware:

```sh
./scripts/test-cooling-recovery.sh
```

Real runtime integration tests are opt-in through `PORTICO_DX12_INTEGRATION_ROOT` (DX12) and `PORTICO_TEST_WINE_PATH` (Wine registry). Ordinary `swift test` runs skip them when those variables are absent.

User data lives under `~/Library/Application Support/Portico/`. Build products, downloaded runtimes, Windows prefixes, logs, signing credentials, and research directories are excluded from Git. The root `.gitignore` explicitly lists the desktop files intended for publication.

## Website and feedback

The promo website and crash/suggestion backend are maintained separately in
[portico-site](https://github.com/delifaxo/portico-site). The live boards are
[crashes](https://185.233.45.102:8443/crashes) and
[suggestions](https://185.233.45.102:8443/suggestions).

In the app, use Report or Help → Suggest an idea. Review the payload and consent
before sending. The public board shows the description and status; diagnostic
logs stay in the private administrator panel. No reports upload automatically.
