# Repository contents and sharing

This is the source repository for Portico Desktop on macOS. The initial publication intentionally includes only:

- The Swift/SwiftUI application, its core library, the cooling helper and native C interface.
- Desktop tests and the simulated cooling recovery test.
- Original icon assets and their generator.
- Portico's C sources and build scripts for the D3D12 diagnostic and Steam compatibility launcher.
- Desktop build/runtime preparation scripts, generic entitlement templates, and technical documentation.
- Existing Wine license notices and upstream provenance metadata under `config/runtime-licenses` for the optional local runtime workflow.

## Excluded components

No Apple SDK, Game Porting Toolkit archive, D3DMetal framework, Apple bridge library, Rosetta binary, provisioning profile, signing certificate, or private key is included. Framework names, API imports, validation code, URLs, and expected runtime paths in source are integration references, not copies of those components.

Wine, GStreamer, WineForge, CrossOver, Valve Steam/client binaries, Microsoft redistributables, games, saved games, Windows prefixes, account data, downloads, application bundles, caches, and local logs are not included either. Neither are the separate iPad probes or research trees.

The two Windows helpers are Portico code, not redistributed Valve or Apple executables. Build them with `scripts/build-assets.sh`; the generated files are ignored by Git. The Steam helper invokes the separately installed original Valve executable.

## Source checkout versus runtime distribution

A clean checkout can build the slim developer app without an embedded runtime. Wine and optional graphics components are installed or connected separately. The dated runtime notes explain the local embedding experiments and their unresolved distribution requirements; they do not supply those binaries or grant third-party distribution rights.

The Wine notices retained here apply to the referenced upstream Wine material. They are not a license for Portico as a whole and do not establish that a future bundled runtime satisfies every dependency's requirements. No new software license is selected by this publication step.

Before sharing an assembled `.app` or a runtime archive, inspect that actual artifact and the terms of every component it contains. The source-only exclusions in this repository do not automatically apply to a separately built bundle.

## Git guardrails

The root `.gitignore` starts with a desktop allowlist and also excludes binary runtimes, installer archives, build output, signing material, local environment files, and iPad research. Do not force-add ignored files. Review `git diff --cached --stat` and the staged paths before future pushes.

The website/API sources live in the separate `delifaxo/portico-site` repository.
The local `Website/` staging directory, report data, admin tokens, certificates and
release archives are excluded from this desktop repository.
