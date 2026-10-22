"""Drive a TV emulator with real Android D-pad keys and record the focus.

For test hosts only: `adb shell input keyevent` reaches the app as a genuine
remote key, and `uiautomator dump` reports the focus the Android accessibility
layer sees, which is what a TV viewer sees. Used to measure the v0.3.2 episode
pager defects (build/verification/tv/v0.3.2/findings.md) and their fix.

    python3 tool/tv_focus_probe.py --device emulator-5554 \
        --out build/verification/tv/focus-fix --tag pager \
        --steps down,down,select,left,right
"""
import argparse
import os
import re
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ADB = Path(
    os.environ.get('ANDROID_HOME', str(Path.home() / 'Library/Android/sdk'))
) / 'platform-tools/adb'
KEYS = {
    'up': 19,
    'down': 20,
    'left': 21,
    'right': 22,
    'select': 23,
    'center': 23,
    'back': 4,
}


def adb(serial, *command, binary=False):
    return subprocess.check_output(
        [str(ADB), '-s', serial, *command],
        text=not binary,
        timeout=60,
        **({} if binary else {'stderr': subprocess.STDOUT}),
    )


def dump(serial):
    """The accessibility tree as XML (uiautomator only writes to a file)."""
    adb(serial, 'shell', 'uiautomator', 'dump', '/sdcard/window_dump.xml')
    return adb(serial, 'shell', 'cat', '/sdcard/window_dump.xml')


def focused(xml):
    """What the remote is pointing at: the deepest focused node that carries a
    label. Flutter's own view container is always focused, so a bare count of
    focused nodes is not a signal -- only a labelled one is."""
    labelled = []
    count = 0
    for tag in re.findall(r'<node\b[^>]*/?>', xml):
        if 'focused="true"' not in tag:
            continue
        count += 1

        def attr(name):
            match = re.search(name + r'="([^"]*)"', tag)
            return match.group(1) if match else ''

        label = attr('content-desc') or attr('text')
        if label:
            labelled.append(f'{label} [{attr("bounds")}]')
    if labelled:
        return labelled[-1] + f' ({count} focused)'
    return f'NO LABELLED FOCUS ({count} focused)'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--tag', default='step')
    parser.add_argument('--steps', required=True, help='comma separated keys')
    parser.add_argument(
        '--settle',
        type=float,
        default=0.8,
        help='seconds to wait after each key before reading',
    )
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=True)
    log = (args.out / f'{args.tag}-focus.log').open('a')

    def record(index, note):
        xml = dump(args.device)
        image = adb(
            args.device, 'exec-out', 'screencap', '-p', binary=True
        )
        name = f'{args.tag}-{index:02d}-{note}'
        (args.out / f'{name}.xml').write_text(xml)
        (args.out / f'{name}.png').write_bytes(image)
        line = f'{index:02d} {note}: {focused(xml)}'
        print(line, flush=True)
        log.write(line + '\n')
        log.flush()

    record(0, 'before')
    for step, key in enumerate([s for s in args.steps.split(',') if s], 1):
        if key != 'wait':
            adb(args.device, 'shell', 'input', 'keyevent', str(KEYS[key]))
        # `wait` injects nothing and only re-reads, for a screen still loading.
        time.sleep(args.settle)
        record(step, key)
    log.close()


if __name__ == '__main__':
    main()
