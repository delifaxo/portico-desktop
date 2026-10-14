#!/usr/bin/env python3
"""Sign an assembled local development app, inside out. Not notarization."""
import argparse
import plistlib
from pathlib import Path
import subprocess

MACHO = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def sign(path):
    label = subprocess.run(['/usr/bin/xattr', '-px', 'com.apple.quarantine', str(path)],
                           capture_output=True, text=True)
    quarantine = ''.join(label.stdout.split()) if label.returncode == 0 else None
    result = subprocess.run(['/usr/bin/codesign', '--force', '--sign', '-', str(path)],
                            capture_output=True, text=True)
    if result.returncode:
        raise RuntimeError(f'Signing failed for {path}: {result.stderr}')
    # Signing may replace a file. Preserve the incoming security label on the copy.
    if quarantine is not None:
        subprocess.run(['/usr/bin/xattr', '-wx', 'com.apple.quarantine', quarantine, str(path)], check=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        parser.error('Expected an assembled .app bundle')
    native_files = []
    with (app / 'Contents/Info.plist').open('rb') as stream:
        main_executable = app / 'Contents/MacOS' / plistlib.load(stream)['CFBundleExecutable']
    frameworks = sorted((app / 'Contents/Frameworks').glob('*.framework'))
    bundle_executables = {main_executable.resolve()}
    for framework in frameworks:
        with (framework / 'Resources/Info.plist').open('rb') as stream:
            name = plistlib.load(stream)['CFBundleExecutable']
        bundle_executables.add((framework / name).resolve())
    for path in app.rglob('*'):
        if path.is_symlink() or not path.is_file() or path.resolve() in bundle_executables:
            continue
        with path.open('rb') as stream:
            if stream.read(4) in MACHO:
                native_files.append(path)
    for path in native_files:
        sign(path)
    for path in frameworks:
        sign(path)
    sign(app)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'Ad-hoc development signatures verified: {len(native_files) + len(bundle_executables)} native files.')
    print('This does not establish Gatekeeper approval, notarization, or App Store readiness.')


if __name__ == '__main__':
    main()
