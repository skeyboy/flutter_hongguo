#!/usr/bin/env python3
import os
from pathlib import Path
from release_meta import ROOT, version

release, _ = version()
folder = ROOT / 'dist'
from plan_build import selected_platforms
platforms = selected_platforms(os.environ.get('RELEASE_PLATFORMS', '["android","macos","windows","linux"]'))
assets = {
    'macos': ['macos-arm64.dmg', 'macos-arm64.zip'],
    'windows': ['windows-x64-setup.exe', 'windows-x64.zip'],
    'linux': ['linux-x64.deb', 'linux-x64.tar.gz'],
    'android-tv': ['android-tv-armeabi-v7a.apk', 'android-tv-arm64-v8a.apk', 'android-tv-x86_64.apk'],
    'android': ['android-armeabi-v7a.apk', 'android-arm64-v8a.apk', 'android-x86_64.apk'],
}
required = [suffix for platform in platforms for suffix in assets[platform]]
for suffix in required:
    file = folder / f'Hongguo-{release}-{suffix}'
    if not file.exists() or file.stat().st_size == 0:
        raise SystemExit(f'Missing installer: {file.name}')
signed = os.environ.get('IOS_SIGNED') == 'true'
if signed and not (folder / f'Hongguo-{release}-ios-arm64.ipa').is_file():
    raise SystemExit('Signed iOS job succeeded but IPA is missing')
ios = 'Signed IPA included; install only on devices covered by its provisioning profile.' if signed else 'iOS was not built in this run. Enable signed iOS explicitly to attach an installable IPA.'
tv = ('Android TV APKs carry a leanback launcher, a home-screen banner and no touchscreen requirement; '
      'every attached TV APK was checked against its own badging before upload.') if 'android-tv' in platforms else 'Android TV was not built in this run.'
(folder / 'iOS-signing-status.txt').write_text(ios + '\n')
notes = ROOT / 'build/release-notes.md'
notes.parent.mkdir(exist_ok=True)
notes.write_text(f'''Native Flutter / shared Dart release {release}.

- macOS: hidden native titlebar, immersive player, scoped always-on-top, retained windows and menu bar controls.
- macOS PiP: automatic next episodes and mouse-driven auto-hiding playback controls.
- Catalog: recover empty upstream responses and sign requests when required.
- My library: favorites, per-episode watch history, resume playback and offline series.
- Episode downloads: select episodes and quality, manage tasks, retry and play offline.
- DLNA casting on Android phones: one cast session belongs to the app rather than to the player page, so stepping away keeps the television running and a draggable floating handle brings the controls back from any page. The remote page drives the whole series: an episode sheet, previous/next, quality switching that puts the playhead back, another television taking the same episode at the same position, and an episode tail that hands on the next one when 自动续播 is on. Playback is only handed back to the phone when the viewer presses 退出投屏. Not yet verified against a physical receiver.
- Search: focusing the box drops a panel with the three most recent queries, each deletable and stored on this device only, plus upstream board picks marked new or hot; a history row runs the search and a board row opens its detail page.
- Player: swipe up or down on the picture to change episodes, touch and stylus only, with a one-time hint on first entry (gesture wording on phones, Page Up/Page Down on desktop) and boundary feedback instead of a silent no-op for keys, buttons and TV remote steps. Gesture behaviour is widget-tested; on-device verification is still open.
- Detail page: watch, download and favorite share one action row and the episode list is now a height-capped block of 3–4 rows that pages sideways (arrow keys, mouse drag or touch), so a long series no longer pushes the page downward. TV keeps the same block on a focusable rail.
- Detail recommendations: a horizontal rail under the episodes reads the upstream genre names of the current drama and shows the matching theme panel page, or the hot board when none of those names is on the panel; the heading only ever says 同题材 · <theme> or 平台热门, because that is exactly what the request asked for. Upstream behaviour is backed by a recorded live response in docs/evidence/related-dramas; on-device verification is still open.
- Downloads: choosing episodes no longer enforces a download size quota, so a whole series can be kept offline; a new 同时下载数量 setting (1–5) caps how many transfers run at once instead, and automatic prefetch keeps its own byte budget so manual downloads cannot starve it.
- Manual downloads survive ordinary cache cleanup; resumed tasks keep independent recovery journals.
- Android TV: the episode grid and other nested grids are reachable with the D-pad (Flutter only walked focus inside the scrollable that owned it), and an item that turns inert no longer drops the page into a state with no focus at all. Verified on an emulator with injected remote key events.
- Adaptive immersive player, unified episode/settings panel, auto_route navigation and cached images.
- Application names follow the system language (English, Simplified and Traditional Chinese).
- Only the selected platforms are built in this run; see the platform list below.
- Android APKs, when selected, use the repository's stable release key.
- {tv}
- {ios}
- macOS is ad-hoc signed, not Apple-notarized; Windows is not Authenticode-signed.

GitHub Actions analysis, shared Dart/core/API tests and Flutter widget tests passed before native builds.
Selected platform builds and installer completeness checks passed before publishing.
Device integration tests were not run in this release workflow; local platform validation limits are documented in the repository.
Platforms built in this run: {', '.join(platforms)}.
SHA256SUMS.txt and release-manifest.json describe the attached files.
''')
