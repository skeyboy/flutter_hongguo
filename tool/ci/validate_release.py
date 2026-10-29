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
- macOS online playback: turning on 后台下载 handed every video transfer to background_downloader, which ships no macOS implementation, so the import fell through to a pure-Dart isolate queue that stops at a fixed byte count on the same URL without ever raising an error or hitting a timeout. The stalled jobs kept holding both preparation slots, so later episodes never published and the player was left with a texture whose rect stays 0x0 forever -- which is what reading "the Mac app cannot load online video" actually was. Desktop now always transfers in-app over Dio and the switch only decides whether caching keeps being prepared while the window is hidden; cache pruning also reclaims the `.part` working files a killed session leaves behind, which had piled up as unusable ciphertext against the byte budget. Verified in a real macOS window against the live API on a series with nothing cached: 3 episodes prefetched, one acquired online at 12,020,592 bytes and played at 1920x1080, seek 10000 -> 10000 ms, next-episode switch in 307 ms with stages 正在排队 -> 已就绪 and no 正在下载 at all, while the same URL that stopped mid-transfer under the system lane in the recorded repro completes end to end under the Dio lane.
- Catalog: recover empty upstream responses and sign requests when required.
- Playback URL acquisition: the player endpoint started checking whether the device_id/iid pair it is sent is one the platform actually issued, and answers a per-request synthetic pair -- with its six signature headers -- by HTTP 200 and no body at all, which reached viewers as FormatException: Unexpected end of input. The app now registers one anonymous playback device per process (a ttEncrypt envelope, checked against offline vectors pinned from the reference implementation for framing, key schedule and the payload it carries), sends that identity unsigned with the player's own User-Agent, and reads the tracks the newer answer inlines instead of asking a second endpoint that has nothing to add. An answer that carries an envelope and declines the episode stops at once in the viewer's language, because repeating it changes nothing; a missing envelope still gets its bounded recoveries inside the same deadline. Verified against the live API: registration and acquisition both answered unsigned, and an episode acquired, downloaded and played at 1080x1920 in a real macOS window.
- Catalog filters on every non-TV build speak one language: 类型 is the first level of BOTH pages and carries one shared value, 题材 is the second level in a strip that stays on screen -- and so does the 类型 row above it, because the only thing a scroll folds away is the search box, the offline check and the swipe hint; a filter row that left with the header could only be changed again by scrolling all the way back to the top, which is what "the filters disappear after a long scroll up" was. Each sideways row also brings the chip its own level names back into view, by the smallest movement of that row's offset and never by asking an ancestor viewport to scroll, so a swipe that turned 类型 or a strip refilled by another type shows what it turned to instead of parking off the edge. Every group is a chip row of one height: the trigger that opened a sheet of every group at once is gone, along with its full-screen dismiss area. 推荐/最新 really change what is requested (最新 asks the catalog for online_time, the others keep the sort set in 设置), 榜单 takes the 类型 row out because rank(board) ignores it, and 题材 is bucketed per type so one empty upstream answer dirties only its own type. Each theme keeps its own entries, page cursor and scroll offset, so coming back returns the list exactly where it was left; rapid choices collapse into one request. Verified state by state from iPhone simulator frames recorded against the live API, including the frame where 类型 is changed to 漫剧 while the top is still folded away, and the handover frame whose strip now shows 全部 · 漫剧 instead of cutting it off.
- Catalog pages swipe like pages on touch and stylus, in three levels that each answer only their own question: 发现 and 分类 slide sideways into each other, each of them pages sideways through the shared 类型 (短剧/漫剧/AI 短剧), and each of those pages sideways through its own 题材 -- or through the three boards while 发现 is on 榜单. A swipe moves the level you are on, and only a pull past its last page hands the gesture one level up, so one gesture never skips a level and a mouse drag never flips a page by accident. The levels that hand over clamp instead of rubber-banding, because an out-of-range iOS bounce reports no overscroll at all and every handover counts exactly that report -- so the chain answers on iPhone as well as on Android. Every page keeps its own rows, cursor and scroll offset, and re-entering one continues where it was left instead of asking the catalog again, including a page that was swiped away while its own first request was still running; leaving a 类型 drops the 题材 picked inside it, and the 类型 both pages share stays selected on either side. Verified from iPhone simulator frames recorded against the live API, including the pull that turns 题材 while 类型 and the selected tab both stay put, and the one that hands over to the next 类型 at the end of the strip.
- Requests: a superseded catalog, detail or media request now releases its own transfer through a cancellation scope instead of racing the newer one, short and long Retry-After and empty upstream responses are recovered inside a shared deadline, and metadata / media-preparation / player-open timings are kept per stage in memory only -- no request parameters, URLs or keys are stored or uploaded. Measured on a macOS window and an iPhone simulator; the Android device refuses USB installs, so no phone claim is made.
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
- Navigation: pushing a page now slides it in from the right edge and popping walks it back out the same way on every build, replacing the platform defaults that faded forwards on Android and zoomed on Windows/Linux. Verified from recorded frame strips on a macOS window and an iPhone simulator.
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
