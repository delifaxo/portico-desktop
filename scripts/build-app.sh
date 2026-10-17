#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
configuration="release"
runtime_directory="$project_root/work/embedded-runtime"
embed_runtime=true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug) configuration="debug"; shift ;;
        --runtime-dir) runtime_directory="${2:?Missing prepared runtime directory}"; shift 2 ;;
        --without-runtime) embed_runtime=false; shift ;;
        *) printf 'Usage: %s [--debug] [--runtime-dir DIRECTORY | --without-runtime]\n' "$0" >&2; exit 2 ;;
    esac
done
if $embed_runtime && [[ ! -f "$runtime_directory/RuntimeManifest.json" ]]; then
    printf 'Prepared embedded runtime is missing: %s\nSee docs/EMBEDDED_RUNTIME.md for preparation; --without-runtime builds the slim developer variant.\n' "$runtime_directory" >&2
    exit 1
fi

if [[ ! -f "$project_root/Assets/Diagnostics/d3d12-probe.exe" || ! -f "$project_root/Assets/Steam/steamwebhelper.exe" ]]; then
    "$project_root/scripts/build-assets.sh"
fi

swift build --package-path "$project_root" --configuration "$configuration" --product Portico
swift build --package-path "$project_root" --configuration "$configuration" --product PorticoCoolingHelper
binary_directory="$(swift build --package-path "$project_root" --configuration "$configuration" --show-bin-path)"
mkdir -p "$project_root/dist" "$project_root/work"
staging_directory="$(mktemp -d "$project_root/dist/.build-XXXXXX")"
bundle_path="$staging_directory/Portico.app"
mkdir -p "$bundle_path/Contents/MacOS" "$bundle_path/Contents/Resources"
cp "$binary_directory/Portico" "$bundle_path/Contents/MacOS/Portico"
chmod +x "$bundle_path/Contents/MacOS/Portico"
cp "$binary_directory/PorticoCoolingHelper" "$bundle_path/Contents/MacOS/PorticoCoolingHelper"
chmod +x "$bundle_path/Contents/MacOS/PorticoCoolingHelper"
if [[ -f "$project_root/Assets/Portico.icns" ]]; then
    cp "$project_root/Assets/Portico.icns" "$bundle_path/Contents/Resources/Portico.icns"
fi
mkdir -p "$bundle_path/Contents/Resources/Diagnostics"
cp "$project_root/Assets/Diagnostics/d3d12-probe.exe" "$bundle_path/Contents/Resources/Diagnostics/d3d12-probe.exe"
mkdir -p "$bundle_path/Contents/Resources/Steam"
cp "$project_root/Assets/Steam/steamwebhelper.exe" "$bundle_path/Contents/Resources/Steam/steamwebhelper.exe"
if $embed_runtime; then
    mkdir -p "$bundle_path/Contents/Frameworks"
    ditto "$runtime_directory/WineRuntime" "$bundle_path/Contents/Frameworks/WineRuntime"
    ditto "$runtime_directory/GStreamer.framework" "$bundle_path/Contents/Frameworks/GStreamer.framework"
    cp "$runtime_directory/RuntimeManifest.json" "$bundle_path/Contents/Resources/RuntimeManifest.json"
    ditto "$project_root/config/runtime-licenses" "$bundle_path/Contents/Resources/RuntimeLicenses"
    if [[ -d "$runtime_directory/ThirdPartyLicenses" ]]; then
        ditto "$runtime_directory/ThirdPartyLicenses" "$bundle_path/Contents/Resources/RuntimeLicenses"
    fi
    python3 "$project_root/scripts/layout-embedded-runtime.py" "$bundle_path"
fi
cat > "$bundle_path/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Portico</string>
    <key>CFBundleIdentifier</key><string>app.portico.mac</string>
    <key>CFBundleName</key><string>Portico</string>
    <key>CFBundleDisplayName</key><string>Portico</string>
    <key>CFBundleIconFile</key><string>Portico</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.3.8</string>
    <key>CFBundleVersion</key><string>11</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
python3 "$project_root/scripts/sign-development-app.py" "$bundle_path"
if [[ -e "$project_root/dist/Portico.app" ]]; then
    previous_directory="$(mktemp -d "$project_root/work/previous-build-XXXXXX")"
    mv "$project_root/dist/Portico.app" "$previous_directory/Portico.app"
fi
mv "$bundle_path" "$project_root/dist/Portico.app"
rmdir "$staging_directory"
printf 'Built %s\n' "$project_root/dist/Portico.app"
