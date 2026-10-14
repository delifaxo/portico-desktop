#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
clang_executable="${PORTICO_CLANG:-$(command -v clang || true)}"
linker="${PORTICO_LLD_LINK:-$(command -v lld-link || true)}"
if [[ -z "$clang_executable" || ! -x "$clang_executable" ]]; then
    printf 'Clang is required. Set PORTICO_CLANG.\n' >&2
    exit 1
fi
if [[ -z "$linker" ]]; then
    host_arch="$(uname -m)"
    if [[ "$host_arch" == arm64 ]]; then host_arch=aarch64; fi
    rustup_directory="${RUSTUP_HOME:-$HOME/.rustup}"
    for candidate in \
        "$(dirname "$clang_executable")/lld-link" \
        /opt/homebrew/opt/llvm/bin/lld-link \
        /usr/local/opt/llvm/bin/lld-link \
        "$rustup_directory/toolchains/stable-$host_arch-apple-darwin/lib/rustlib/$host_arch-apple-darwin/bin/gcc-ld/lld-link"; do
        if [[ -x "$candidate" ]]; then linker="$candidate"; break; fi
    done
fi
if [[ -z "$linker" || ! -x "$linker" ]]; then
    printf 'lld-link is required. Set PORTICO_LLD_LINK to an installed LLVM or Rust toolchain linker.\n' >&2
    exit 1
fi
build_directory="$project_root/work/steam-helper-build"
mkdir -p "$build_directory" "$project_root/Assets/Steam"
"$clang_executable" --target=x86_64-pc-windows-msvc -c -O2 -ffreestanding -fno-stack-protector \
    "$project_root/Compatibility/Steam/webhelper.c" -o "$build_directory/webhelper.obj"
"$linker" /lib /machine:x64 "/def:$project_root/Compatibility/Steam/kernel32.def" "/out:$build_directory/kernel32.lib"
"$linker" /entry:mainCRTStartup /subsystem:windows /nodefaultlib /machine:x64 \
    "/out:$project_root/Assets/Steam/steamwebhelper.exe" "$build_directory/webhelper.obj" "$build_directory/kernel32.lib"
