# Portico: first setup

English | [Українська](GETTING_STARTED.uk.md)

Open **Getting started** in the app's sidebar. This section opens automatically when your library is empty. You can return to it when setting up another game or environment. Use the **ENG** language option to follow the English button names below.

If you are starting from the source code, first follow [Build from a clean clone](../README.md#build-from-a-clean-clone). The slim app built with `--without-runtime` does not include Wine or Apple graphics components; install or connect the required runtime separately.

## 1. Check Wine

If you have a local full build with Wine and its media libraries embedded, click **Check bundled Wine** and wait for the engine check to finish.

If Wine is missing, open **Install or select engine…**, download it using the app's button or select an existing compatible Wine installation. Wait for validation to finish. On Apple Silicon, x86_64 Wine requires Rosetta 2. If macOS offers to install it, complete the system dialog and check the engine again.

## 2. Choose the graphics runtime

Check the DirectX version in your game's system requirements.

- **DirectX 9:** start with standard Wine. You can select the `DirectX 9 · WineD3D` profile later using the gear button on the game's card.
- **DirectX 11/12:** open **Set up DirectX 11/12…** and connect a complete compatible Wine + D3DMetal runtime. The dialog provides a source link and a local runtime selector. A DMG or a standalone D3DMetal library is not enough.

The appropriate graphics setup depends on the game. Selecting the DirectX 9 profile does not make a game that requires DirectX 12 run with DirectX 9.

## 3. Create an environment

Click **Create environment…**, enter a name, and select the graphics engine. Wait until the environment is ready. A D3DMetal environment also runs a DirectX 12 diagnostic.

Select a ready environment in step 3 for the following actions. Install Steam, prerequisites, and the game into that same environment. You can create separate environments for games with different requirements. Switching a game's environment in its card does not move its files or saved games.

## 4. Install Steam or your game

**For a Steam copy:** select **Steam**, then click **Download and install Steam**. Wait for the Windows client to download and update. Sign in through the Steam window and open its library. Enter your password and Steam Guard code only in Steam.

**For your own installer:** select **Your .exe / .msi installer**, click **Open installer…**, and follow its steps. Install the game onto the selected environment's C: drive. Find the installed game's `.exe`; the installer itself is not the game's launch executable.

## 5. Add the game to Portico

**Steam:** install the game in Windows Steam and wait for the download to finish. In Portico, click **Refresh list**, then **Add games from Steam**. The card will use Steam in that environment.

**Your own installer:** click **Add game**, select the environment, and choose the installed game's `.exe`. If the game expects its data next to its executable, keep the default working directory or select that folder explicitly.

## 6. Save the configuration and test the game

Open the gear button on the game's card and check:

1. **Launch with:** Steam, directly through an `.exe`, or an existing CrossOver launcher. Start with the Steam launch method for Steam copies.
2. **Environment and engine:** select the environment where the game is installed.
3. **Game graphics:** keep the environment's automatic graphics or select `DirectX 9 · WineD3D`. For Steam games, select the game's own `.exe` if Portico cannot identify it unambiguously. This does not change the Steam launch method.
4. Click **Save**. Before launching, or after reopening the gear button, click **Apply configuration**. The game must be closed; Steam may remain open.
5. If the game needs legacy D3DX9/D3DCompiler libraries, click **Download and install DirectX components…**. The Microsoft June 2010 package is approximately 100 MB; Portico verifies the download. Complete the separate installer window. Install Visual C++ prerequisites from the game's included package or prerequisite installer.
6. Click Play on the game's card, review the launch checklist, and click **Launch game**. Check the menu, a gameplay scene, sound, and controls.

The DirectX 9 profile applies to the selected `.exe` in the selected environment. To return to automatic graphics, save and apply the configuration again; Portico restores the previous values for the settings it changed. If two games have executables with the same filename, use separate environments to keep their graphics settings separate. Ready components do not establish compatibility with every game.

## If the game does not start

- **No Steam window / black library:** wait for the client to update, then check the Steam section and the selected environment's log. Restart Steam after closing the game.
- **Application load error / no Steam apps:** check that the card uses the Steam launch method and the environment where that game is installed.
- **D3D feature level 12_0 required:** check the compatible D3DMetal runtime and the environment's DirectX 12 diagnostic.
- **Missing D3DX9 / D3DCompiler:** install the legacy DirectX components and apply the game's graphics profile again.

Each game's launch result needs a separate check. This guide does not automatically change the game's resolution, FPS limit, or other in-game settings.
