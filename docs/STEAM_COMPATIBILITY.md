# Steam on the bundled Wine 11

The September 2026 Steam client crashes in GPTK's Wine 7.7 when CEF delay-loads
`QueryUnbiasedInterruptTimePrecise`. Use a separate Wine 11 prefix. Never migrate
a working D3DMetal/Gothic prefix in place or mix Wine and wineserver releases.

`Bottle.steamDesktop = true` opts into a 1280×800 Wine desktop and a small CEF
argument launcher. It runs the original Valve helper with `--disable-gpu
--single-process`. Source is in `Compatibility/Steam`, built with
`bash scripts/build-steam-helper.sh`. No third-party executable is downloaded.

The original helper is retained byte-for-byte with a SHA-256 receipt. On a later
launch, an updated official helper replaces that backup before the launcher is
installed again. Symlinks, missing/changed backups and unknown small launchers
fail closed. The environment must be idle before helper files are changed.

Steam is launched with `-noverifyfiles` so its executable verification does not
immediately replace the compatibility launcher. This is an experimental client
workaround, not a guarantee of compatibility with future Steam updates. Updates
are not disabled; if an update replaces the launcher during startup, close the
client and reopen it through Portico. Steam itself handles account login, Steam
Guard, ownership checks and game downloads. This mode does not add DX12 or a new
graphics translator to Wine 11, and does not imply game compatibility.

To restore manually with the prefix stopped: validate the original against
`portico-webhelper.json`, copy it back over `steamwebhelper.exe`, then disable
the environment's `steamDesktop` setting. Do not delete user account data.

## WineForge profile in 0.3.4

The local WineForge/D3DMetal profile uses the original Steam webhelper in a native window, with `-cef-disable-sandbox` scoped to Steam. It does not install the legacy single-process wrapper or pass `-noverifyfiles`. Its graphics environment explicitly disables WineForge's optional automatic WFDXCompat layer, which crashed KCD II during device creation in testing. See `WINEFORGE_LOCAL.md` for the verified runtime layout, limitations and launch evidence.
