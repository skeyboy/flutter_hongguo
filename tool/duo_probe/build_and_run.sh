#!/bin/bash
# iPhone Duo 折叠感知探针：编译 → 打包 → 装进模拟器 → 采样打印 JSON → 收起。
# 中间物放 TMPDIR（外接卷上 simctl 写不进），读数落到同目录 evidence/。
# 用法：
#   ./build_and_run.sh                 # 默认采 20s（够覆盖一次换姿势）
#   DUO_SAMPLE_SECONDS=60 ./build_and_run.sh
#   DUO_SHOT=1 ./build_and_run.sh      # 顺带截一张当前帧
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
BUNDLE_ID="com.hongguo.duoprobe"
UDID="${DUO_SIM_UDID:-A285E6A3-1006-4D70-9D4F-C7D919EB2C5C}"
SAMPLE_SECONDS="${DUO_SAMPLE_SECONDS:-20}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/duo-probe-XXXXXX")"
APP="$WORK/duoprobe.app"
BIN_NAME="duoprobe"
OUT="$WORK/probe.jsonl"
trap 'rm -rf "$WORK"' EXIT

echo "== 目标设备 =="
xcrun simctl list devices -j | python3 -c "
import json,sys
d=json.load(sys.stdin)['devices']
want='$UDID'
hit=False
for rt,devs in d.items():
    for x in devs:
        if x['udid']==want:
            hit=True
            print('  name=%s state=%s runtime=%s' % (x['name'],x['state'],rt.split('.')[-1]))
print('  !! 未找到该 UDID，请用 xcrun simctl create 建一个 iPhone Duo 设备' if not hit else '')
"

SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDK_VER="$(xcrun --sdk iphonesimulator --show-sdk-version)"
echo "== 编译（iOS Simulator SDK $SDK_VER, arm64）=="
mkdir -p "$APP"
BUILD_LOG="$WORK/build.log"
if ! xcrun -sdk iphonesimulator swiftc \
  -target "arm64-apple-ios${SDK_VER}-simulator" \
  -sdk "$SDK_PATH" \
  -framework UIKit -framework Foundation \
  -o "$APP/$BIN_NAME" "$HERE/main.swift" >"$BUILD_LOG" 2>&1; then
  echo "!! 编译失败：" >&2
  grep -E "error:" "$BUILD_LOG" | head -15 >&2
  exit 1
fi
grep -E "warning:.*(deprecated)" "$BUILD_LOG" | sed -e 's/^/  (弃用提醒) /' | head -5 || true

cat > "$APP/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key><string>$BIN_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleName</key><string>duoprobe</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSRequiresIPhoneOS</key><true/>
  <key>UIDeviceFamily</key><array><integer>1</integer><integer>2</integer></array>
  <key>UILaunchScreen</key><dict/>
  <key>UIApplicationSceneManifest</key>
  <dict>
    <key>UIApplicationSupportsMultipleScenes</key><false/>
    <key>UISceneConfigurations</key>
    <dict>
      <key>UIWindowSceneSessionRoleApplication</key>
      <array>
        <dict>
          <key>UISceneConfigurationName</key><string>Probe</string>
          <key>UISceneDelegateClassName</key><string>ProbeSceneDelegate</string>
        </dict>
      </array>
    </dict>
  </dict>
  <key>UISupportedInterfaceOrientations</key>
  <array><string>UIInterfaceOrientationPortrait</string>
         <string>UIInterfaceOrientationLandscapeLeft</string>
         <string>UIInterfaceOrientationLandscapeRight</string></array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP" >/dev/null 2>&1

STATE="$(xcrun simctl list devices -j | python3 -c "
import json,sys
for rt,devs in json.load(sys.stdin)['devices'].items():
    for x in devs:
        if x['udid']=='$UDID': print(x['state'])
")"
if [ "$STATE" != "Booted" ]; then
  echo "== 启动模拟器 =="
  xcrun simctl boot "$UDID"
  open -a Simulator >/dev/null 2>&1 || true
  sleep 6
fi

echo "== 安装并启动（采样 ${SAMPLE_SECONDS}s；期间可在 Simulator 里换折叠姿势）=="
xcrun simctl install "$UDID" "$APP"
CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [ -n "$CONTAINER" ]; then
  rm -f "$CONTAINER/Documents/samples.jsonl"
fi
xcrun simctl launch "$UDID" "$BUNDLE_ID" --terminate-running-process >/dev/null
PROBE_PID="$(xcrun simctl spawn "$UDID" launchctl list 2>/dev/null | grep -i duoprobe | awk '{print $1}' | head -1 || true)"
[ -n "${DUO_SHOT:-}" ] && sleep 3 && xcrun simctl io "$UDID" screenshot "$WORK/frame.png" 2>/dev/null || true
sleep "$SAMPLE_SECONDS"
[ -n "${DUO_SHOT:-}" ] && xcrun simctl io "$UDID" screenshot "$WORK/frame2.png" 2>/dev/null || true
xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true

CONTAINER="$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null || true)"
if [ -n "$CONTAINER" ] && [ -f "$CONTAINER/Documents/samples.jsonl" ]; then
  cp "$CONTAINER/Documents/samples.jsonl" "$OUT"
fi

if [ ! -s "$OUT" ]; then
  echo "!! 探针没有产出任何读数（$OUT 为空）" >&2
  exit 1
fi

echo "== 读数摘要 =="
python3 - "$OUT" <<'PY'
import json,sys
raw=[json.loads(l.split("DUOPROBE ",1)[1]) for l in open(sys.argv[1]) if "DUOPROBE " in l]
markers=[r for r in raw if "seq" not in r]
rows=[r for r in raw if "seq" in r]
if markers:
    print("标记:", "; ".join("%s %.0fx%.0f@%.0f" % (m.get("marker"), m.get("screenBounds",{}).get("w",0), m.get("screenBounds",{}).get("h",0), m.get("screenScale",0)) for m in markers))
if not rows:
    print("无样本"); raise SystemExit(1)
print("样本数:", len(rows), " 时间跨度: %.2fs" % (rows[-1]["t"]-rows[0]["t"]))
def shape(r):
    v=r["viewBounds"]; return "%.0fx%.0f" % (v["w"], v["h"])
def brief(rs):
    return "; ".join("%s %.0fx%.0f@(%.0f,%.0f) act=%s m=(t%.0f l%.0f b%.0f r%.0f)" % (
        x["kind"], x["frame"]["w"], x["frame"]["h"], x["frame"]["x"], x["frame"]["y"], x["active"],
        x["margins"]["t"], x["margins"]["l"], x["margins"]["b"], x["margins"]["r"]) for x in rs) or "-"
seen=set()
for r in rows:
    ws=r["windowScene"]
    key=(shape(r), r["hinge"]["status"], r["traits"]["hSizeClass"], r["traits"]["vSizeClass"],
         tuple(round(x,1) for x in (r["safeArea"]["t"],r["safeArea"]["l"],r["safeArea"]["b"],r["safeArea"]["r"])),
         brief(r["divisionAll"]), len(r["divisionActive"]), len(r["occlusionAll"]),
         ws["interactivelyResizing"] if isinstance(ws,dict) else "-")
    if key in seen: continue
    seen.add(key)
    print("--- seq %d ---" % r["seq"])
    print("  view=%s pt | screen=%s pt @scale %s (native %s)" % (
        shape(r), "%.0fx%.0f" % (r["screen"]["bounds"]["w"], r["screen"]["bounds"]["h"]),
        r["screen"]["scale"], r["screen"]["nativeScale"]))
    print("  sizeClass H=%s V=%s" % (r["traits"]["hSizeClass"], r["traits"]["vSizeClass"]))
    print("  safeArea t=%.1f l=%.1f b=%.1f r=%.1f" % (
        r["safeArea"]["t"], r["safeArea"]["l"], r["safeArea"]["b"], r["safeArea"]["r"]))
    if isinstance(ws,dict):
        print("  scene: screen=%.0fx%.0f @%.0f  orientation=%s  geom=%s  interactivelyResizing=%s" % (
            ws["screenBounds"]["w"], ws["screenBounds"]["h"], ws["screenScale"],
            ws["orientation"],
            "%.0fx%.0f" % (ws["geomCoordSpace"]["w"], ws["geomCoordSpace"]["h"]),
            ws["interactivelyResizing"]))
    print("  hinge=%s angle=%.4f rad (%.1f°) updates=%d" % (
        r["hinge"]["status"], r["hinge"]["angle"], r["hinge"]["angle"]*180/3.141592653589793,
        r["hinge"]["updates"]))
    print("  division  active-only = %s" % brief(r["divisionActive"]))
    print("  division  incl-inact  = %s" % brief(r["divisionAll"]))
    print("  occlusion all         = %s" % brief(r["occlusionAll"]))
print("\n== 切换时刻（hinge / division / 屏尺寸 / 安全区任一变化）==")
prev=None
for r in rows:
    cur=(r["hinge"]["status"], len(r["divisionActive"]), len(r["divisionAll"]), shape(r),
         r["traits"]["hSizeClass"],
         tuple(round(x,1) for x in (r["safeArea"]["t"],r["safeArea"]["l"],r["safeArea"]["b"],r["safeArea"]["r"])))
    if cur!=prev:
        print("  dt=%7.3fs seq=%3d hinge=%-14s divActive=%d divAll=%d view=%-9s H=%-8s safe=(%.0f,%.0f,%.0f,%.0f)" % (
            r["t"]-rows[0]["t"], r["seq"], cur[0], cur[1], cur[2], cur[3], cur[4], *cur[5]))
        prev=cur
PY

STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
EVID="$HERE/evidence"
mkdir -p "$EVID"
cp "$OUT" "$EVID/duo-$STAMP.jsonl"
echo "== 原始读数已存 $EVID/duo-$STAMP.jsonl （probe PID 记录：${PROBE_PID:-未捕获}）=="
