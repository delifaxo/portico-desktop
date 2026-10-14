#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
"$project_root/scripts/build-d3d12-probe.sh"
"$project_root/scripts/build-steam-helper.sh"
