#!/usr/bin/env python3
"""Exercise the real embedded Wine in a new, isolated development prefix."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('--work-dir', type=Path, default=Path('work'))
    args = parser.parse_args()
    app = args.app.resolve(strict=True)
    contents = app / 'Contents'
    manifest = json.loads((contents / 'Resources/RuntimeManifest.json').read_text())
    wine = contents / 'Frameworks/WineRuntime/bin/wine'
    server = wine.with_name('wineserver')
    gst = contents / 'Frameworks/GStreamer.framework/Versions/Current'
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    args.work_dir.mkdir(parents=True, exist_ok=True)
    evidence = Path(tempfile.mkdtemp(prefix='embedded-check-', dir=args.work_dir)).resolve()
    prefix = evidence / 'prefix'
    env = dict(os.environ)
    for key in list(env):
        if key.startswith(('WINE', 'GST_', 'GIO_', 'DYLD_')):
            env.pop(key)
    env.update(WINEPREFIX=str(prefix), WINELOADER=str(wine), WINESERVER=str(server), WINEDEBUG='-all',
               WINEDLLOVERRIDES='winemenubuilder.exe=d',
               GST_PLUGIN_SYSTEM_PATH_1_0=str(gst / 'lib/gstreamer-1.0'),
               GST_PLUGIN_SCANNER_1_0=str(gst / 'libexec/gstreamer-1.0/gst-plugin-scanner'),
               GIO_EXTRA_MODULES=str(gst / 'lib/gio/modules'),
               GIO_MODULE_DIR=str(gst / 'lib/gio/modules'),
               GST_REGISTRY_1_0=str(evidence / 'gstreamer-registry.bin'))
    checks = []

    def check(label, executable, arguments, timeout):
        with (evidence / (label + '.log')).open('w') as log:
            result = subprocess.run([str(executable), *arguments], env=env, stdout=log,
                                    stderr=subprocess.STDOUT, timeout=timeout)
        output = (evidence / (label + '.log')).read_text(errors='replace')
        checks.append({'check': label, 'exitCode': result.returncode, 'outputTail': output[-4000:]})
        print(f'{label}: exit {result.returncode}\n{output[-600:]}', flush=True)
        if result.returncode != 0:
            raise RuntimeError(f'{label} failed; see {evidence}')
        return output

    try:
        check('wine-version', wine, ['--version'], 15)
        check('wineboot', wine, ['wineboot.exe', '-u'], 150)
        check('wineboot-wait', server, ['-w'], 30)
        if not (prefix / 'drive_c').is_dir() or not (prefix / 'system.reg').is_file():
            raise RuntimeError('Wine returned success without a usable prefix')
        output = check('windows-command', wine, ['cmd.exe', '/c', 'echo', 'PORTICO_EMBEDDED_OK'], 30)
        check('windows-command-wait', server, ['-w'], 30)
        if 'PORTICO_EMBEDDED_OK' not in output:
            raise RuntimeError('Windows command output was not verified')
        report = {'passed': True, 'app': str(app), 'runtime': manifest, 'checks': checks,
                  'limits': 'Basic Windows process only; no game, 3D, sandbox or distribution validation.'}
    except Exception as error:
        report = {'passed': False, 'app': str(app), 'error': str(error), 'checks': checks}
        raise
    finally:
        # Never stop any other installation or prefix.
        subprocess.run([str(server), '-k'], env=env, capture_output=True, timeout=10)
        subprocess.run([str(server), '-w'], env=env, capture_output=True, timeout=15)
        (evidence / 'result.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'Evidence: {evidence}', flush=True)


if __name__ == '__main__':
    main()
