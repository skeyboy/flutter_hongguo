"""Project-local Android installation policy; never changes global SDK settings."""
from contextlib import contextmanager
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


def adb_command(device, *args):
    return [shutil.which('adb') or 'adb', '-s', device, *args]


@contextmanager
def android_test_environment():
    """Give Flutter a temporary SDK view whose adb uses push installation.

    All SDK files remain symlinks to the original SDK. Only the subprocess
    environment changes; no device security settings or Flutter source edits.
    """
    flutter = Path(__file__).resolve().parents[1] / '.fvm/flutter_sdk/bin/flutter'
    config = subprocess.run([str(flutter), 'config', '--list'], capture_output=True,
                            text=True, check=True).stdout
    if any(line.strip().startswith('android-sdk:') and '(Not set)' not in line
           for line in config.splitlines()):
        raise RuntimeError('Explicit Flutter android-sdk overrides temporary ADB policy; '
                           'this tester requires SDK selection through ANDROID_HOME')
    sdk = Path(os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT')
               or Path.home() / 'Library/Android/sdk').resolve()
    if not (sdk / 'platform-tools/adb').is_file():
        raise RuntimeError('Set ANDROID_HOME to the installed Android SDK')
    real_adb = str(sdk / 'platform-tools/adb')
    with tempfile.TemporaryDirectory(prefix='hongguo-mobile-sdk-') as folder:
        view = Path(folder)
        for item in sdk.iterdir():
            if item.name != 'platform-tools':
                (view / item.name).symlink_to(item, target_is_directory=item.is_dir())
        platform_tools = view / 'platform-tools'
        platform_tools.mkdir()
        for item in (sdk / 'platform-tools').iterdir():
            if item.name != 'adb':
                (platform_tools / item.name).symlink_to(item, target_is_directory=item.is_dir())
        wrapper = platform_tools / 'adb'
        wrapper.write_text(
            f'#!{sys.executable}\nimport os, sys\n'
            'args = sys.argv[1:]\n'
            'if "uninstall" in args and "shell" not in args:\n'
            '    print("Refusing automatic uninstall: preserve app data", file=sys.stderr)\n'
            '    sys.exit(1)\n'
            'if "install" in args and "shell" not in args and "--no-streaming" not in args:\n'
            '    args.insert(args.index("install") + 1, "--no-streaming")\n'
            '    print("[hongguo-adb] push install (--no-streaming)", file=sys.stderr)\n'
            f'os.execv({real_adb!r}, [{real_adb!r}, *args])\n'
        )
        wrapper.chmod(0o755)
        env = os.environ.copy()
        env.update(ANDROID_HOME=str(view), ANDROID_SDK_ROOT=str(view))
        # AGP must not cache temporary bootclasspath paths in a shared daemon.
        env['GRADLE_OPTS'] = env.get('GRADLE_OPTS', '') + ' -Dorg.gradle.daemon=false'
        env['ORG_GRADLE_PROJECT_kotlin.compiler.execution.strategy'] = 'in-process'
        yield env


def install_apk(device, apk):
    apk = Path(apk).resolve(strict=True)
    # Signature/version conflicts are errors. Never uninstall to force an update.
    result = subprocess.run(adb_command(device, 'install', '--no-streaming', '-r', '-t', str(apk)),
                            text=True, capture_output=True, timeout=90)
    print(result.stdout, end='')
    print(result.stderr, end='', file=sys.stderr)
    if result.returncode or 'Success' not in result.stdout:
        raise RuntimeError('ADB update failed; existing app/data were not uninstalled')
