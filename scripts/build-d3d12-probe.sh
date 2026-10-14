#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ $# -ne 0 ]]; then
    printf 'Usage: %s\nOptional tool paths: PORTICO_CLANG and PORTICO_LLD_LINK\n' "$0" >&2
    exit 2
fi

clang_executable="${PORTICO_CLANG:-$(command -v clang || true)}"
linker_executable="${PORTICO_LLD_LINK:-$(command -v lld-link || true)}"
if [[ -z "$clang_executable" || ! -x "$clang_executable" ]]; then
    printf 'Clang is required. Install Xcode Command Line Tools or set PORTICO_CLANG.\n' >&2
    exit 1
fi

if [[ -z "$linker_executable" ]]; then
    host_arch="$(uname -m)"
    if [[ "$host_arch" == "arm64" ]]; then host_arch="aarch64"; fi
    rust_host="$host_arch-apple-darwin"
    rustup_directory="${RUSTUP_HOME:-$HOME/.rustup}"
    for candidate in \
        "$(dirname "$clang_executable")/lld-link" \
        /opt/homebrew/opt/llvm/bin/lld-link \
        /usr/local/opt/llvm/bin/lld-link \
        /Library/Developer/CommandLineTools/usr/bin/lld-link \
        "$rustup_directory/toolchains/stable-$rust_host/lib/rustlib/$rust_host/bin/gcc-ld/lld-link"; do
        if [[ -x "$candidate" ]]; then linker_executable="$candidate"; break; fi
    done
fi
if [[ -z "$linker_executable" || ! -x "$linker_executable" ]]; then
    printf 'lld-link is required. Set PORTICO_LLD_LINK to an installed LLVM or Rust toolchain linker.\n' >&2
    exit 1
fi

build_directory="$project_root/work/d3d12-probe-build"
asset_directory="$project_root/Assets/Diagnostics"
mkdir -p "$build_directory" "$asset_directory"
"$clang_executable" --target=x86_64-pc-windows-msvc -c -O2 -ffreestanding -fno-stack-protector \
    "$project_root/Diagnostics/d3d12-probe.c" -o "$build_directory/probe.obj"
"$linker_executable" /lib /machine:x64 \
    "/def:$project_root/Diagnostics/d3d12-probe-kernel32.def" "/out:$build_directory/kernel32.lib"
"$linker_executable" /entry:mainCRTStartup /subsystem:console /nodefaultlib /machine:x64 \
    "/out:$build_directory/d3d12-probe.exe" "$build_directory/probe.obj" "$build_directory/kernel32.lib"
cp "$build_directory/d3d12-probe.exe" "$asset_directory/d3d12-probe.exe.new"
mv "$asset_directory/d3d12-probe.exe.new" "$asset_directory/d3d12-probe.exe"
printf 'Built %s\n' "$asset_directory/d3d12-probe.exe"
