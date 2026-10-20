"""Check or enable emulator hardware keyboard/D-pad support for a TV AVD.

Apply only while the AVD is stopped, then cold-boot it. Never wipes device data.
"""
import argparse
from pathlib import Path
import re
import shutil


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--avd', default='hongguo_tv_api34')
    parser.add_argument('--apply', action='store_true')
    parser.add_argument('--graphics', action='store_true', help='Also enable the TV emulator graphics backend')
    args = parser.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9_-]+', args.avd):
        raise SystemExit('Invalid AVD name')
    path = Path.home() / '.android/avd' / (args.avd + '.avd') / 'config.ini'
    text = path.read_text()
    desired = {'hw.dPad': 'yes', 'hw.keyboard': 'yes', 'hw.keyboard.lid': 'no'}
    if args.graphics:
        desired.update({'hw.gpu.enabled': 'yes', 'hw.gpu.mode': 'swiftshader'})
    values = dict(line.strip().split('=', 1) for line in text.splitlines() if '=' in line)
    values = {key.strip(): value.strip() for key, value in values.items()}
    invalid = [key for key, value in desired.items() if values.get(key) != value]
    if invalid and not args.apply:
        raise SystemExit('Hardware remote configuration requires: ' + ', '.join(invalid))
    if invalid:
        backup = path.with_name('config.before-hardware-remote.ini')
        if not backup.exists():
            shutil.copy2(path, backup)
        for key, value in desired.items():
            pattern = r'^' + re.escape(key) + r'\s*=.*$'
            if re.search(pattern, text, re.M):
                text = re.sub(pattern, key + '=' + value, text, flags=re.M)
            else:
                text += '\n' + key + '=' + value + '\n'
        path.write_text(text)
    print('PASS: ' + args.avd + ' hardware keyboard/D-pad settings')

if __name__ == '__main__':
    main()
