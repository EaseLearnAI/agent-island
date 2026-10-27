#!/bin/bash
# Agent Island · build + package
# Output (<repo>/build/):
#   AgentIsland.app
#   AgentIsland-<version>.dmg   drag the app into Applications
#   AgentIsland-<version>.zip   same content as a zip
# 签名：有 Developer ID Application 证书 + 设置了 NOTARY_PROFILE（xcrun notarytool store-credentials 存的名字）时，
#       自动开启 hardened runtime 并公证，别人双击就能打开；否则用 Apple Development / ad-hoc 签名，
#       别人第一次打开需要在「系统设置 → 隐私与安全性」里点「仍要打开」（见 首次打开说明.txt）。
# Usage: bash scripts/build.sh
set -euo pipefail
export PATH=/usr/bin:/bin:/usr/sbin:/sbin:$PATH

HERE="$(cd "$(dirname "$0")/.." && pwd)"          # repo root
REPO="$HERE"
VERSION="$(tr -d '[:space:]' < "$HERE/VERSION")"
# build number = commits on HEAD (monotonic), commit = short sha (+dirty) — shown in About / --version / --check
BUILD="$(git -C "$HERE" rev-list --count HEAD 2>/dev/null || echo 0)"
COMMIT="$(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo local)"
if [ -n "$(git -C "$HERE" status --porcelain -- Sources scripts 2>/dev/null)" ]; then COMMIT="$COMMIT-dirty"; fi
OUT="$REPO/build"
APP="$OUT/AgentIsland.app"
TMP="$REPO/test/tmp/build"
rm -rf "$TMP"; mkdir -p "$TMP" "$OUT"
trap 'rm -rf "$TMP"' EXIT
BUNDLE_ID="io.github.easelearnai.agent-island"
NAME="AgentIsland-$VERSION"

echo "==> Agent Island $VERSION (build $BUILD, $COMMIT)"
rm -rf "$APP" "$OUT"/AgentIsland-*.dmg "$OUT"/AgentIsland-*.zip
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "==> 1. 编译（arm64 + x86_64 通用二进制）"
BINS=()
for ARCH in arm64 x86_64; do
  if swiftc -O -target "$ARCH-apple-macos14.0" -o "$TMP/AgentIsland-$ARCH" "$HERE"/Sources/*.swift \
       -framework AppKit -framework SwiftUI -lsqlite3 2>"$TMP/$ARCH.log"; then
    BINS+=("$TMP/AgentIsland-$ARCH")
    echo "    $ARCH ok"
  else
    echo "    $ARCH 编译失败："; tail -20 "$TMP/$ARCH.log"; exit 1
  fi
done
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/AgentIsland"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Agent Island</string>
  <key>CFBundleDisplayName</key><string>Agent Island</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>AgentIsland</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD</string>
  <key>AgentIslandCommit</key><string>$COMMIT</string>
  <key>CFBundleDevelopmentRegion</key><string>zh_CN</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>MIT License · reads local agent state only, offline</string>
</dict>
</plist>
EOF

echo "==> 2. 图标"
"$APP/Contents/MacOS/AgentIsland" --render-icon "$TMP/icon.png"
ICONSET="$TMP/AppIcon.iconset"; mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d "$TMP/icon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "==> 3. 签名"
IDS="$(security find-identity -v -p codesigning 2>/dev/null || true)"
DEVID=$(echo "$IDS" | awk -F'"' '/Developer ID Application/ {print $2; exit}')
DEV=$(echo "$IDS" | awk -F'"' '/Apple Development/ {print $2; exit}')
NOTARIZE=0
if [ -n "$DEVID" ] && [ -n "${NOTARY_PROFILE:-}" ]; then
  codesign --force --deep --options runtime --timestamp -s "$DEVID" "$APP"
  NOTARIZE=1; echo "    $DEVID（hardened runtime，稍后公证）"
else
  # 用固定证书签名，TCC（辅助功能授权）按签名记，重装 / 升级后授权不丢
  SIGN="${DEVID:-${DEV:--}}"
  codesign --force --deep -s "$SIGN" "$APP"
  echo "    ${SIGN/#-/ad-hoc}（未公证：别人首次打开需要「仍要打开」）"
fi
codesign --verify --deep --strict "$APP"

STAGE="$TMP/stage"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
cp "$HERE/docs/FIRST_OPEN.md" "$STAGE/首次打开说明 First open.md"

echo "==> 4. DMG"
DMG="$OUT/$NAME.dmg"
ln -s /Applications "$STAGE/应用程序"
hdiutil create -quiet -volname "Agent Island $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"
rm "$STAGE/应用程序"
if [ "$NOTARIZE" = 1 ]; then
  codesign --force --timestamp -s "$DEVID" "$DMG"
  echo "    公证中（几分钟）…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
elif [ -n "$DEV" ]; then
  codesign --force -s "$DEV" "$DMG" 2>/dev/null || true
fi
echo "    $DMG ($(du -h "$DMG" | cut -f1))"

echo "==> 5. zip"
cp "$HERE/README.md" "$STAGE/README.md"
mv "$STAGE" "$TMP/$NAME"
(cd "$TMP" && ditto -c -k --norsrc --keepParent "$NAME" "$OUT/$NAME.zip")
echo "    $OUT/$NAME.zip ($(du -h "$OUT/$NAME.zip" | cut -f1))"
echo "完成。"
