#!/usr/bin/env bash
# Read-only structural checks. This script never builds, signs, installs, or edits files.
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -gt 1 ]]; then
    printf 'Usage: %s [path/to/Portico.app]\n' "$0" >&2
    exit 2
fi
bundle_path="${1:-$project_root/dist/Portico.app}"
blockers=0

block() {
    blockers=$((blockers + 1))
    printf 'BLOCKER: %s\n' "$1"
}

entitlement_is_true() {
    local target="$1" key="$2" entitlement_plist value key_path
    entitlement_plist="$(/usr/bin/codesign --display --entitlements :- "$target" 2>/dev/null)" || return 1
    key_path="${key//./\\.}"
    value="$(printf '%s' "$entitlement_plist" | /usr/bin/plutil -extract "$key_path" raw -o - - 2>/dev/null)" || return 1
    [[ "$value" == "true" ]]
}

check_signature() {
    local target="$1" label="$2" details
    if ! /usr/bin/codesign --verify --strict "$target" >/dev/null 2>&1; then
        block "$label: підпис відсутній або не проходить перевірку."
        return
    fi
    details="$(/usr/bin/codesign --display --verbose=4 "$target" 2>&1)" || {
        block "$label: не вдалося прочитати підпис."
        return
    }
    case "$details" in
        *"Authority=Apple Distribution:"*|*"Authority=3rd Party Mac Developer Application:"*)
            printf 'OK: %s — підпис для App Store наявний.\n' "$label"
            ;;
        *) block "$label: потрібен підпис App Store distribution; ad-hoc, development і Developer ID не підходять для цієї перевірки." ;;
    esac
}

printf 'Перевірка: %s\n' "$bundle_path"
if [[ ! -d "$bundle_path" ]]; then
    block 'Bundle відсутній. Спочатку потрібна окрема збірка кандидата; цей скрипт її не створює.'
    exit 1
fi

check_signature "$bundle_path" 'Застосунок'
if ! /usr/bin/codesign --verify --deep --strict "$bundle_path" >/dev/null 2>&1; then
    block 'Підпис bundle та розпізнаного вкладеного коду не проходить сувору перевірку.'
fi
if entitlement_is_true "$bundle_path" 'com.apple.security.app-sandbox'; then
    printf 'OK: App Sandbox entitlement наявний.\n'
else
    block 'Основний застосунок не підписано з App Sandbox.'
fi
if entitlement_is_true "$bundle_path" 'com.apple.security.cs.disable-library-validation'; then
    block 'Основний застосунок містить широке виключення disable-library-validation; потрібна окрема перевірка архітектури.'
fi

main_name="$(/usr/bin/plutil -extract CFBundleExecutable raw -o - "$bundle_path/Contents/Info.plist" 2>/dev/null)" || main_name=""
if [[ -z "$main_name" || "$main_name" == */* || ! -x "$bundle_path/Contents/MacOS/$main_name" ]]; then
    block 'Основний виконуваний файл bundle не знайдено.'
else
    check_signature "$bundle_path/Contents/MacOS/$main_name" 'Основний executable'
fi

runtime_directory="$bundle_path/Contents/Frameworks/WineRuntime"
if [[ ! -d "$runtime_directory" ]]; then
    block 'У bundle відсутній Contents/Frameworks/WineRuntime. Зовнішня інсталяція Wine не замінює вбудований runtime у профілі APP_STORE.'
else
    printf 'OK: каталог WineRuntime наявний.\n'
    for helper in wine wineserver; do
        helper_path="$runtime_directory/bin/$helper"
        if [[ ! -f "$helper_path" || ! -x "$helper_path" ]]; then
            block "Не знайдено виконуваний helper WineRuntime/bin/$helper."
            continue
        fi
        check_signature "$helper_path" "$helper"
        if ! entitlement_is_true "$helper_path" 'com.apple.security.app-sandbox'; then
            block "$helper: відсутній App Sandbox entitlement."
        fi
        if ! entitlement_is_true "$helper_path" 'com.apple.security.inherit'; then
            block "$helper: відсутній sandbox inheritance entitlement."
        fi
    done
fi

printf '\nЦя перевірка не запускає Wine й не підтверджує APP_STORE compilation flag, sandbox-сумісність, права на runtime або схвалення Apple.\n'
if [[ $blockers -gt 0 ]]; then
    printf 'Виявлено блокувальних умов: %s.\n' "$blockers"
    exit 1
fi
printf 'Структурні перевірки пройдено. Перед поданням потрібні функціональні sandbox-тести, перевірка всього вкладеного коду й App Review.\n'
