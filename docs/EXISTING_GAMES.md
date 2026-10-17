# Already installed games

An existing game's files can be selected in Portico without downloading another copy. A regular `.exe` card uses a Portico-managed Wine environment and the executable's original directory as its default working directory. Its registry, Windows prerequisites, graphics support, and Steam session must be available in that environment; pointing at an executable does not transfer them.

Do not initialize an existing CrossOver bottle with standalone Wine. Use a separate Portico environment when testing a different runtime.

## Optional CrossOver shortcut import

The library's **Add from CrossOver** action discovers Menu Helper `.app` shortcuts in `~/Applications/CrossOver`, with manual selection for other locations. Import stores a reference in `Library.crossOverGames`; game files, saves, bottles, and engine binaries are not copied. Removing a card removes only that reference.

Cards show **CrossOver** as their engine. Play revalidates the shortcut and opens it with macOS LaunchServices. Portico does not evaluate the command stored in its plist. CrossOver handles the actual Steam/game launch and process lifetime. The displayed confirmation means the launch request was handed off, not that gameplay has been verified. The recent timestamp records that request. Quit the game from its own window.

The external shortcut path is disabled in the App Store build profile. It does not change the standalone Wine adapter or provide an embedded CrossOver runtime.

## Removing games

Click the Trash button on a library card (or **Remove game…** in its context menu). The confirmation window offers two choices:

- **Library entry only** removes the card and its Portico launch settings. Installed files, saves, and the Windows environment stay in place. The game can be added again.
- **Uninstall game files** opens the Windows Steam uninstall confirmation for Steam games. Keep the Portico removal window open until Steam finishes: Portico removes the card only after the installation folder disappears and a successful Steam scan no longer finds the game. Cancelling in Steam leaves the card intact. For standalone `.exe` games, explicitly select the dedicated game folder and confirm **Move to Trash**. Everything inside that folder, including any saves there, goes to Trash; saves elsewhere stay in place. Empty Trash to reclaim space. This folder-based option does not run a Windows uninstaller or clean its registry entries.

For CrossOver cards, **Uninstall game files** opens CrossOver. Choose the card's bottle, uninstall the game from its installed software list, then remove its Portico card. Portico does not delete an external CrossOver bottle.

Removal is blocked during managed game launches and preparation. Folder removal rejects shared library roots, Windows/system folders, symbolic links, runtime bundles, and folders used by another library card. A failed filesystem operation keeps the card. If saving the library fails after a successful move, the folder is recoverable from Trash and Portico reports the storage error.

## Local verification, 2026-09-05

- Found a fully installed Gothic 1 Remake in the existing CrossOver Steam library (38,333,717,785 bytes according to Steam's local manifest, state flag 4).
- Imported its real CrossOver shortcut through the separate Portico test app UI and pressed Play. The helper opened and Portico recorded the handoff. No game window was observed; successful gameplay is **not confirmed**.
- The user then requested a launch without CrossOver. No further CrossOver launch was attempted. The original downloaded standalone Wine was not approved by macOS (`spctl`: no usable signature); a separate task is preparing the embedded runtime. Gothic's standalone DirectX 12 launch remains unverified.
- Test UI uses `work/crossover-test/Portico CrossOver Test.app` and an isolated library at `work/crossover-test/library`. The production library and existing CrossOver bottle configuration were not edited for this test.
- Core tests cover shortcut discovery/validation, changed or missing launchers, old-library decoding, roundtrip persistence, duplicate rejection, and the App Store gate.

## Standalone Gothic prerequisites, 2026-09-06

The downloaded Wine 11.0_1 contains `d3d12.dll`, vkd3d 1.18 in `wined3d.dll`, Wine Vulkan modules, and `libMoltenVK.dylib`. There is an existing DX12 → Vulkan → Metal path; the absence of D3DMetal does not mean no DX12 implementation exists.

The installed Gothic executable imports the Visual C++ runtime and includes Steam API initialization/restart references. Its VC 2022 installers already exist under the Steam library's `Steamworks Shared/_CommonRedist/vcredist/2022`, and the game contains `Engine/Extras/Redist/en-us/UEPrereqSetup_x64.exe`. Plan for a working Windows Steam client in the new Portico environment; see [Valve's initialization requirements](https://partner.steamgames.com/doc/api/steam_api#SteamAPI_Init).

Gothic exports Agility SDK version/path data and ships its own `D3D12/D3D12Core.dll`. Wine 11.0's built-in `d3d12core` exposes stub interfaces ([upstream source](https://raw.githubusercontent.com/wine-mirror/wine/wine-11.0/dlls/d3d12core/d3d12core.spec)). This is a compatibility concern to investigate with an actual launch log, not a measured failure of Gothic. Do not report either success or definite incompatibility before that test.

Full source/UI regression check after this integration: `swift test --scratch-path work/crossover-build` passed 81 tests, with zero failures. These tests do not demonstrate game compatibility.

## Actual standalone launch result, 2026-09-06

The final embedded runtime at `dist/Portico.app/Contents/Frameworks/WineRuntime/bin/wine` successfully created the isolated prefix `work/standalone-gothic/prefix` (`wineboot.exe -u`, exit 0). The game was then launched from its existing installation using this runtime and private GStreamer environment, with no CrossOver executable or bottle initialization.

- Default launch: the game ran and MoltenVK created a device on Apple M4 Max. The user reported its error: **“DirectX 12 is not supported on your system. Try running without the -dx12 or -d3d12 command line argument.”** No `-dx12` or `-d3d12` flag was passed; this was the game's default selection.
- Explicit `-dx11` diagnostic: unattended run exited with code 3. A subsequent normal diagnostic produced the user-reported message: **“Unable to launch with RHI 'DirectX 11' since the project is not configured to support it.”** Therefore DirectX 11 is not a fallback in this installed build.
- Conclusion: embedded Wine startup works, but Gothic gameplay is blocked by the current DX12 graphics compatibility. No game files were downloaded, replaced, or patched. A different compatible DX12 implementation requires a separate integration and real-game validation.

Logs and reproducible local diagnostic runner are in `work/standalone-gothic/`. Only that test prefix's processes were stopped after the failed attempts; existing CrossOver environments and the production Portico library were not changed.


## D3DMetal launch confirmed, Portico 0.3.1, 2026-09-06

The managed GPTK 3.0-3 runtime was allowed using macOS's per-app Open Anyway control after user authorization. Quarantine and original Apple signatures remain intact; global Gatekeeper policy was not changed. Portico's static spctl veto was corrected because the actual user-approved Wine launch succeeds while static signature assessment still rejects the unsigned upstream wrapper.

The production Portico environment `DirectX 12 · D3DMetal` completed Wine initialization and device diagnostics, reporting FL12_2 / SM6.6. Its Gothic card points to the existing `G1R/Binaries/Win64/G1R-Win64-Shipping.exe` and uses the separate managed GPTK Wine/server. No CrossOver runtime or existing CrossOver prefix was executed or reinitialized.

The inner game executable was launched directly through Portico. D3DMetal rendered/issued game commands, and the process ended with Wine/server exit0. The user explicitly confirmed that **the game started**. This establishes game startup, not a measured frame rate or extended gameplay certification. D3DMetal emitted unsupported query API notices in the log, so rendering/performance remain subjects for further gameplay testing.

Evidence: `work/dx12-031-validation/gothic-launch.log`, `ui-graphics-report.json`; final suite139 tests passed including real managed runtime integration.
