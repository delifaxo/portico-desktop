#!/usr/bin/env python3
"""Keep Wine's Windows files in Resources while preserving its logical paths."""
import argparse
import os
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    contents = args.app.resolve(strict=True) / 'Contents'
    runtime = contents / 'Frameworks/WineRuntime'
    resources = contents / 'Resources/WineRuntime'
    # PE executables are interpreted by Wine, not signed as macOS native code.
    # Their presence under Frameworks causes codesign to treat them as native helpers.
    for relative in ['lib/wine/i386-windows', 'lib/wine/x86_64-windows', 'share']:
        source = runtime / relative
        target = resources / relative
        if source.is_symlink() and source.resolve() == target:
            continue
        if not source.is_dir() or target.exists():
            raise RuntimeError(f'Unexpected Wine layout: {source}')
        target.parent.mkdir(parents=True, exist_ok=True)
        source.rename(target)
        source.symlink_to(os.path.relpath(target, source.parent), target_is_directory=True)


if __name__ == '__main__':
    main()
