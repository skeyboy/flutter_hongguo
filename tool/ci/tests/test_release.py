import base64
import hashlib
import json
import os
from pathlib import Path
import re
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

CI = Path(__file__).resolve().parents[1]
REPO = CI.parents[1]
sys.path.insert(0, str(CI))
import release_meta

# Captured from `aapt2 dump badging` on a real tv-flavor build.
TV_BADGING = """package: name='com.example.hongguo_app.tv' versionCode='10' versionName='0.2.8' platformBuildVersionName='16'
minSdkVersion:'24'
targetSdkVersion:'36'
application: label='Hongguo TV' icon='res/mipmap-anydpi-v33/ic_launcher.xml' banner='res/drawable-xhdpi-v4/tv_banner.png'
launchable-activity: name='com.example.hongguo_app.MainActivity'  label='' icon=''
leanback-launchable-activity: name='com.example.hongguo_app.MainActivity'  label='' icon='' banner=''
feature-group: label=''
  uses-feature-not-required: name='android.hardware.touchscreen'
  uses-feature: name='android.software.leanback'
  uses-feature: name='android.hardware.screen.landscape'
"""


class ReleaseContractTest(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = Path(self.folder.name)
        (self.root / 'packages/app').mkdir(parents=True)
        for path in (self.root / 'pubspec.yaml', self.root / 'packages/app/pubspec.yaml'):
            path.write_text('version: 0.2.3+5\n')
        (self.root / '.fvmrc').write_text('{"flutter":"3.47.4"}')
        # Release metadata also reads the version constant the running app
        # shows its users, so the fixture has to carry one that agrees.
        dart_dir = self.root / 'packages/app/lib/update'
        dart_dir.mkdir(parents=True)
        (dart_dir / 'app_release.dart').write_text(
            "static const version = '0.2.3';\nstatic const build = 5;\n"
        )
        self.environment = patch.dict(os.environ, GITHUB_REF='refs/heads/test', GITHUB_SHA='test-commit', RELEASE_PLATFORMS='["android","macos","windows","linux"]')
        self.environment.start()
        self.addCleanup(self.environment.stop)
        self.root_patch = patch.object(release_meta, 'ROOT', self.root)
        self.root_patch.start()
        self.addCleanup(self.root_patch.stop)
        self.addCleanup(self.folder.cleanup)

    def test_tag_must_match_actual_app_version(self):
        with patch.dict(os.environ, GITHUB_REF='refs/tags/v0.2.3'):
            self.assertEqual(release_meta.version(), ('0.2.3', '5'))
        with patch.dict(os.environ, GITHUB_REF='refs/tags/v0.2.4'):
            with self.assertRaises(SystemExit):
                release_meta.version()
        (self.root / 'packages/app/pubspec.yaml').write_text('version: 0.2.2+4\n')
        with self.assertRaises(SystemExit):
            release_meta.version()

    def test_dart_version_constant_must_not_lag_the_pubspec(self):
        constant = self.root / 'packages/app/lib/update/app_release.dart'
        constant.write_text("static const version = '0.2.2';\nstatic const build = 4;\n")
        with self.assertRaises(SystemExit):
            release_meta.version()
        constant.write_text("static const version = '0.2.3';\nstatic const build = 4;\n")
        with self.assertRaises(SystemExit):
            release_meta.version()

    def test_release_gate_rejects_missing_installers(self):
        (self.root / 'dist').mkdir()
        with self.assertRaises(SystemExit):
            runpy.run_path(str(CI / 'validate_release.py'))
        for suffix in ['macos-arm64.dmg', 'macos-arm64.zip', 'windows-x64-setup.exe', 'windows-x64.zip',
                       'linux-x64.deb', 'linux-x64.tar.gz', 'android-armeabi-v7a.apk', 'android-arm64-v8a.apk', 'android-x86_64.apk']:
            (self.root / 'dist' / f'Hongguo-0.2.3-{suffix}').write_bytes(b'contract test only')
        with patch.dict(os.environ, IOS_SIGNED='false'):
            runpy.run_path(str(CI / 'validate_release.py'))
        self.assertIn('iOS was not built', (self.root / 'dist/iOS-signing-status.txt').read_text())
        with patch.dict(os.environ, IOS_SIGNED='true'):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(CI / 'validate_release.py'))

    def test_selective_release_requires_only_selected_assets(self):
        dist = self.root / 'dist'
        dist.mkdir()
        for abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']:
            (dist / f'Hongguo-0.2.3-android-{abi}.apk').write_bytes(b'fixture')
        with patch.dict(os.environ, RELEASE_PLATFORMS='["android"]', IOS_SIGNED='false'):
            runpy.run_path(str(CI / 'validate_release.py'))
        from plan_build import selected_platforms
        self.assertEqual(selected_platforms('["android","macos"]'), ['android', 'macos'])
        for raw in ['[]', '["ios"]', '["android","android"]', '{}', '[1]', 'invalid']:
            with self.assertRaises(SystemExit):
                selected_platforms(raw)

    def test_tv_release_is_independent_of_mobile_installers(self):
        from plan_build import selected_platforms
        self.assertEqual(selected_platforms('["android-tv"]'), ['android-tv'])
        dist = self.root / 'dist'
        dist.mkdir()
        for abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']:
            (dist / f'Hongguo-0.2.3-android-{abi}.apk').write_bytes(b'mobile fixture')
        with patch.dict(os.environ, RELEASE_PLATFORMS='["android-tv"]', IOS_SIGNED='false'):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(CI / 'validate_release.py'))
            for abi in ['armeabi-v7a', 'arm64-v8a', 'x86_64']:
                (dist / f'Hongguo-0.2.3-android-tv-{abi}.apk').write_bytes(b'tv fixture')
            runpy.run_path(str(CI / 'validate_release.py'))

    def test_tv_badging_gate_accepts_a_real_tv_build(self):
        from tv_package import badging_problems
        self.assertEqual(badging_problems(TV_BADGING), [])

    def test_tv_badging_gate_rejects_builds_that_cannot_run_on_tv(self):
        from tv_package import badging_problems
        mobile = TV_BADGING.replace("name='com.example.hongguo_app.tv'", "name='com.example.hongguo_app'")
        self.assertTrue(any('applicationId' in p for p in badging_problems(mobile)))
        no_banner = TV_BADGING.replace("banner='res/drawable-xhdpi-v4/tv_banner.png'", "banner=''")
        self.assertTrue(any('banner' in p for p in badging_problems(no_banner)))
        phone_only = '\n'.join(line for line in TV_BADGING.splitlines() if 'leanback-launchable' not in line)
        self.assertTrue(any('LEANBACK_LAUNCHER' in p for p in badging_problems(phone_only)))
        touch_required = TV_BADGING.replace(
            "uses-feature-not-required: name='android.hardware.touchscreen'",
            "uses-feature: name='android.hardware.touchscreen'")
        self.assertTrue(any('touchscreen' in p for p in badging_problems(touch_required)))
        leanback_optional = TV_BADGING.replace(
            "uses-feature: name='android.software.leanback'",
            "uses-feature-not-required: name='android.software.leanback'")
        self.assertTrue(any('leanback' in p for p in badging_problems(leanback_optional)))
        self.assertEqual(badging_problems(''),
                         ['badging output has no package line, so the APK could not be read'])

    def test_default_release_matrix_includes_android_tv(self):
        from plan_build import selected_platforms
        rows = []
        for name in ('.github/workflows/build.yml', '.github/workflows/release.yml', 'tool/publish_github.sh'):
            rows += [(name, raw) for raw in re.findall(r"'(\[\"[^\]]*\])'", (REPO / name).read_text())]
        self.assertGreaterEqual(len(rows), 5)
        for name, raw in rows:
            platforms = selected_platforms(raw)
            if {'android', 'macos', 'windows', 'linux'} <= set(platforms):
                self.assertIn('android-tv', platforms, f'{name} default matrix dropped Android TV: {raw}')

    def test_checksums_use_portable_asset_names(self):
        dist = self.root / 'dist'
        dist.mkdir()
        (dist / 'app.zip').write_bytes(b'package')
        with patch.object(sys, 'argv', ['release_meta.py', 'checksums', str(dist)]):
            release_meta.main()
        rows = (dist / 'SHA256SUMS.txt').read_text()
        self.assertIn(f'{hashlib.sha256(b"package").hexdigest()}  app.zip', rows)
        self.assertNotIn(str(self.root), rows)
        self.assertEqual(json.loads((dist / 'release-manifest.json').read_text())['version'], '0.2.3')

    def test_android_secret_restore_fails_closed_and_writes_private_file(self):
        with patch.dict(os.environ, KEYSTORE='', STORE_PASSWORD='', KEY_PASSWORD='', KEY_ALIAS=''):
            with self.assertRaises(SystemExit):
                runpy.run_path(str(CI / 'restore_android_signing.py'))
        env_file = self.root / 'environment'
        with patch.dict(os.environ, KEYSTORE=base64.b64encode(b'test fixture').decode(),
                        STORE_PASSWORD='test-password', KEY_PASSWORD='test-password', KEY_ALIAS='test-alias',
                        RUNNER_TEMP=str(self.root), GITHUB_ENV=str(env_file)):
            runpy.run_path(str(CI / 'restore_android_signing.py'))
        self.assertEqual((self.root / 'hongguo-release.jks').read_bytes(), b'test fixture')
        self.assertIn('ANDROID_KEY_ALIAS=test-alias', env_file.read_text())
        self.assertEqual((self.root / 'hongguo-release.jks').stat().st_mode & 0o777, 0o600)


if __name__ == '__main__':
    unittest.main()
