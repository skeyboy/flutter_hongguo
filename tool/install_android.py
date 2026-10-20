"""Update this project's Android APK using ADB, retaining application data."""
import argparse
from pathlib import Path
from mobile_devices import install_apk

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--apk', type=Path, default=Path(__file__).resolve().parents[1] /
                        'packages/app/build/app/outputs/flutter-apk/app-debug.apk')
    args = parser.parse_args()
    install_apk(args.device, args.apk)
