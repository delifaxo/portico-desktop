#!/usr/bin/env bash
set -euo pipefail
project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
test_binary="$(mktemp -t portico-cooling-recovery)"
trap 'rm -f "$test_binary"' EXIT
clang -I "$project_root/Sources/CoolingSMC/include" \
    "$project_root/Tests/CoolingSMCTests/recovery.c" \
    -framework IOKit -framework CoreFoundation -o "$test_binary"
"$test_binary"
