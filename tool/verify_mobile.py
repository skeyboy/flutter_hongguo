"""Run real-viewport mobile UI tests and Android system Back/Home checks."""
import argparse
from concurrent.futures import ThreadPoolExecutor
from contextlib import nullcontext
import json
from pathlib import Path
import subprocess
import time
from mobile_devices import adb_command, android_test_environment

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = 'com.example.hongguo_app'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=['android', 'ios'], required=True)
    parser.add_argument('--device', required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--require-system-back', action='store_true')
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    log = args.output / f'{args.platform}-device.log'
    operations = []

    def adb(*params):
        result = subprocess.run(adb_command(args.device, *params), text=True,
                                capture_output=True, timeout=20)
        if result.returncode or 'SecurityException' in result.stdout + result.stderr:
            raise RuntimeError('Device command failed: ' + result.stdout + result.stderr)
        return result.stdout

    def system_action(kind):
        if kind == 'back':
            adb('shell', 'input', 'keyevent', 'KEYCODE_BACK')
            record = {'kind': kind, 'actual_system_key': True}
        else:
            activity = adb('shell', 'dumpsys', 'activity', 'activities')
            resumed = [line for line in activity.splitlines() if 'topResumedActivity=' in line]
            if not any(PACKAGE in line for line in resumed):
                raise RuntimeError('Target app is not foreground; refusing unrelated UI interaction')
            adb('shell', 'am', 'start', '-W', '-a', 'android.intent.action.MAIN',
                '-c', 'android.intent.category.HOME')
            time.sleep(3)
            activity = adb('shell', 'dumpsys', 'activity', 'activities')
            resumed = [line for line in activity.splitlines() if 'topResumedActivity=' in line]
            background = bool(resumed) and all(PACKAGE not in line for line in resumed)
            if not background:
                raise RuntimeError('System launcher did not move the target app to background')
            record = {'kind': kind, 'home_intent_started': True,
                      'target_not_foreground': background, 'wait_seconds': 3}
            if kind == 'playback':
                record['media_session_present'] = PACKAGE in adb('shell', 'dumpsys', 'media_session')
                record['service_running'] = PACKAGE in adb('shell', 'dumpsys', 'activity', 'services', PACKAGE)
            else:
                record['system_job_present'] = PACKAGE in adb('shell', 'dumpsys', 'jobscheduler')
            adb('shell', 'am', 'start', '-n', PACKAGE + '/.MainActivity')
        operations.append(record)
        print('DEVICE_OPERATION=' + json.dumps(record), flush=True)

    command = [str(ROOT / '.fvm/flutter_sdk/bin/flutter'), 'test',
               'integration_test/offline_playback_test.dart', '--no-uninstall', '--timeout', '90s', '-d', args.device]
    native_back = False
    if args.platform == 'android':
        command += ['--flavor', 'mobile']
        try:
            adb('shell', 'input', 'keyevent', 'KEYCODE_UNKNOWN')
            native_back = True
        except RuntimeError:
            operations.append({'kind': 'system_back', 'status': 'not_tested',
                               'reason': 'OEM denies shell INJECT_EVENTS permission'})
            print('SYSTEM_BACK_UNAVAILABLE=OEM input injection permission denied; not counted as passed', flush=True)
            if args.require_system_back:
                raise RuntimeError('Enable device-specific secure debugging to require system Back testing')
        command += ['--dart-define=HONGGUO_TEST_BACKGROUND=true',
                    f'--dart-define=HONGGUO_DEVICE_GESTURES={str(native_back).lower()}']
    policy = android_test_environment() if args.platform == 'android' else nullcontext(None)
    local_properties = ROOT / 'packages/app/android/local.properties'
    original_properties = local_properties.read_bytes() if local_properties.exists() else None
    try:
        with policy as env, ThreadPoolExecutor(max_workers=1) as pool, log.open('w') as output:
            if args.platform == 'android':
                env['HONGGUO_TEST_ABI'] = adb('shell', 'getprop', 'ro.product.cpu.abi').strip()
                print('DEVICE_TEST_ABI=' + env['HONGGUO_TEST_ABI'], flush=True)
            proc = subprocess.Popen(command, cwd=ROOT / 'packages/app', env=env, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1)
            try:
                pending, seen = [], set()
                for line in proc.stdout:
                    print(line, end='', flush=True)
                    output.write(line)
                    output.flush()
                    if args.platform == 'android':
                        if 'DEVICE_SCREENSHOT=' in line:
                            name = line.split('DEVICE_SCREENSHOT=', 1)[1].strip()
                            if name and all(c.isalnum() or c == '-' for c in name):
                                image = subprocess.run(adb_command(args.device, 'exec-out', 'screencap', '-p'),
                                                       capture_output=True, timeout=10, check=True).stdout
                                if not image.startswith(b'\x89PNG'):
                                    raise RuntimeError('Device did not return a PNG screenshot')
                                (args.output / (name + '.png')).write_bytes(image)
                        for marker, kind in [('MOBILE_BACK_WINDOW=', 'back'),
                                             ('NATIVE_DOWNLOAD_BACKGROUND_WINDOW=', 'download'),
                                             ('MOBILE_BACKGROUND_WINDOW=', 'playback')]:
                            if marker in line and marker not in seen:
                                seen.add(marker)
                                pending.append(pool.submit(system_action, kind))
                code = proc.wait()
                for future in pending:
                    future.result()
                if not code and args.platform == 'android' and len(seen) != (3 if native_back else 2):
                    raise RuntimeError('Missing required actual system verification markers')
            finally:
                if proc.poll() is None:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()
    finally:
        # Flutter writes sdk.dir into ignored local.properties. Restore it after
        # discarding the temporary SDK view so normal developer builds work.
        if original_properties is not None:
            local_properties.write_bytes(original_properties)
        elif local_properties.exists():
            local_properties.unlink()
        (args.output / f'{args.platform}-system-operations.json').write_text(
            json.dumps(operations, indent=2) + '\n')
    return code


if __name__ == '__main__':
    raise SystemExit(main())
