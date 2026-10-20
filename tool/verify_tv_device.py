"""Run native TV integration with actual Android D-pad/Back input via ADB."""
import argparse
import json
import os
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
ADB = Path(os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))) / 'platform-tools/adb'

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--allow-no-keys', action='store_true', help='Allow tests that do not exercise remote input')
    parser.add_argument('--test', default='integration_test/tv_remote_test.dart')
    parser.add_argument('--input-source', choices=['adb', 'emulator'], default='adb')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/verification/tv-emulator')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    def adb(*command):
        return subprocess.check_output([str(ADB), '-s', args.device, *command], text=True, timeout=30).strip()
    profile = {
        'device': args.device,
        'abi': adb('shell', 'getprop', 'ro.product.cpu.abi'),
        'android': adb('shell', 'getprop', 'ro.build.version.release'),
        'features': adb('shell', 'pm', 'list', 'features').splitlines(),
        'display': adb('shell', 'wm', 'size'),
        'density': adb('shell', 'wm', 'density'),
        'input_source': args.input_source,
    }
    (args.output / 'device.json').write_text(json.dumps(profile, ensure_ascii=False, indent=2) + '\n')
    env = os.environ.copy()
    env['HONGGUO_TEST_ABI'] = profile['abi']
    command = [str(ROOT / '.fvm/flutter_sdk/bin/flutter'), 'test',
               args.test, '--flavor', 'tv',
               '--no-pub', '--no-uninstall', '--dart-define=HONGGUO_SYSTEM_DPAD=true',
               '--reporter', 'expanded', '-d', args.device]
    remote = None
    if args.input_source == 'emulator':
        from emulator_remote import EmulatorRemote
        remote = EmulatorRemote(args.device)
    keys = []
    with (args.output / 'system-dpad-test.log').open('w') as log:
        process = subprocess.Popen(command, cwd=ROOT / 'packages/app', env=env,
                                   stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                   text=True, bufsize=1)
        try:
            for line in process.stdout:
                print(line, end='', flush=True)
                log.write(line)
                log.flush()
                capture = re.search(r'TV_SCREENSHOT=([a-z0-9-]+)', line)
                if capture:
                    image = subprocess.check_output([str(ADB), '-s', args.device, 'exec-out', 'screencap', '-p'], timeout=15)
                    (args.output / (capture.group(1) + '.png')).write_bytes(image)
                match = re.search(r'TV_SYSTEM_KEY=(\d+)', line)
                if match:
                    code = int(match.group(1))
                    if remote is not None:
                        remote.press(code)
                        source = 'emulator-grpc-evdev'
                    else:
                        adb('shell', 'input', 'keyevent', str(code))
                        source = 'android-shell-input'
                    if not keys and not args.allow_no_keys:
                        activity = adb('shell', 'dumpsys', 'activity', 'activities')
                        (args.output / 'first-key-activity.txt').write_text(activity)
                        window = adb('shell', 'dumpsys', 'window', 'windows')
                        (args.output / 'first-key-window.txt').write_text(window)
                        image = subprocess.check_output([str(ADB), '-s', args.device, 'exec-out', 'screencap', '-p'], timeout=15)
                        (args.output / 'first-key-screen.png').write_bytes(image)
                    keys.append({'code': code, 'source': source, 'success': True})
            result = process.wait()
        finally:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=15)
            (args.output / 'system-keys.json').write_text(json.dumps(keys, indent=2) + '\n')
    if result:
        raise SystemExit(result)
    if not keys and not args.allow_no_keys:
        raise SystemExit('No Android system keys were executed')

if __name__ == '__main__':
    main()
