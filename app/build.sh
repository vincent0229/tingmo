#!/bin/bash
# Builds E1录音助手.app (universal: Apple silicon + Intel) and a drag-to-install .dmg.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.3.2}"
NAME="听墨"
APP="build/$NAME.app"

# PREVIEW=1 ./build.sh makes a build whose screenshot mode (-uiPreview YES …) works; release builds leave it out.
FLAGS=(); [ "${PREVIEW:-0}" = "1" ] && FLAGS=(-Xswiftc -DE1_PREVIEW)
swift build -c release --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"}
BIN="$(swift build -c release --arch arm64 --arch x86_64 ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)/E1Recorder"

rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/E1Recorder"
# SwiftPM records the deployment target as the SDK version; macOS would then draw the app with the old look.
# Stamp the real SDK so the system applies the current design (glass toolbar, menu bar panel, sidebar).
xcrun vtool -set-build-version macos 15.0 "$(xcrun --sdk macosx --show-sdk-version)" -replace \
  -output "$APP/Contents/MacOS/E1Recorder" "$APP/Contents/MacOS/E1Recorder"
# Drop debug symbols: they record the build machine's source paths (and so the user name).
xcrun strip -S -x "$APP/Contents/MacOS/E1Recorder"

# adb (Android platform-tools, Apache-2.0) is bundled so the app works on a fresh Mac
ADB="$(python3 -c 'import os,shutil;print(os.path.realpath(shutil.which("adb")))')"
cp "$ADB" "$APP/Contents/Resources/adb"
cp "$(dirname "$ADB")/NOTICE.txt" "$APP/Contents/Resources/adb-NOTICE.txt"
cp ../pen/e1sync.sh ../pen/auto_reboot.sh "$APP/Contents/Resources/"
# WiFi uploader for the pen (Linux arm64, static). Needs Go: brew install go
(cd ../pen/e1wifi && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -trimpath -buildvcs=false -ldflags "-s -w" -o build/e1wifi-arm64 .)
cp ../pen/e1wifi/build/e1wifi-arm64 "$APP/Contents/Resources/"
WIFI_VERSION="$(grep -o 'const version = "[^"]*"' ../pen/e1wifi/main.go | cut -d'"' -f2)"
# App icon: Icon Composer file → Assets.car (macOS 26+ glass icon) + AppIcon.icns (older systems)
# 听墨 fork: 无完整 Xcode（仅 CLT）时 actool 不可用，跳过图标编译，回退系统默认图标
if xcrun --find actool >/dev/null 2>&1; then
  xcrun actool "$PWD/Resources/AppIcon.icon" --compile "$PWD/$APP/Contents/Resources" --platform macosx \
    --minimum-deployment-target 15.0 --app-icon AppIcon --output-partial-info-plist "$PWD/build/icon-partial.plist" >/dev/null
  rm -f build/icon-partial.plist
else
  echo "actool 不可用（需要完整 Xcode），跳过图标编译"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.tingmo.mac</string>
  <key>CFBundleDevelopmentRegion</key><string>zh-Hans</string>
  <key>CFBundleLocalizations</key><array><string>zh-Hans</string></array>
  <key>CFBundleName</key><string>$NAME</string>
  <key>CFBundleDisplayName</key><string>$NAME</string>
  <key>CFBundleExecutable</key><string>E1Recorder</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleDocumentTypes</key><array><dict>
    <key>CFBundleTypeName</key><string>录音</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.audio</string><string>public.mpeg-4-audio</string><string>public.movie</string></array>
  </dict></array>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>E1WifiVersion</key><string>$WIFI_VERSION</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>用于在菜单栏面板里直接录音，录完自动转写成会议纪要。</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 seabird000 · MIT 许可</string>
</dict></plist>
PLIST

# Declare Chinese so system panels (Finder open/save dialogs, menus) appear in Chinese
mkdir -p "$APP/Contents/Resources/zh-Hans.lproj"
printf '"CFBundleDisplayName" = "听墨";\n"CFBundleName" = "听墨";\n' > "$APP/Contents/Resources/zh-Hans.lproj/InfoPlist.strings"

# Signing: with a local self-signed "E1Recorder Local Signing" certificate (made once in Keychain Access ›
# Certificate Assistant › Create a Certificate…, type "Code Signing") every build keeps the same identity, so macOS
# asks for Keychain access only once instead of after every rebuild. Without it, ad-hoc signing as before.
# The certificate's name can be overridden per machine in app/.signing-identity (not in git).
SIGN_ID="${SIGN_ID:-$(cat .signing-identity 2>/dev/null || echo "E1Recorder Local Signing")}"
if security find-certificate -c "$SIGN_ID" >/dev/null 2>&1; then
  codesign --force --sign "$SIGN_ID" "$APP"
  echo "signed with: $SIGN_ID"
else
  codesign --force --sign - "$APP"
  echo "signed ad-hoc (no \"$SIGN_ID\" certificate in the keychain)"
fi

STAGE="build/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/应用程序"
cat > "$STAGE/安装说明.txt" <<'TXT'
E1录音助手 安装说明

1. 把「E1录音助手」拖到「应用程序」文件夹。
2. 第一次打开：在「应用程序」里右键点 E1录音助手 →「打开」→ 再点「打开」。
   （本应用未经 Apple 公证，macOS 第一次会拦一下，这样操作一次即可。）
3. 先在录音笔上打开 adb：通用设置 → 关于本机 → 连续点「MAC 地址」→ 开发者模式 → 基本设置 → adb 打开。
4. 打开应用后跟着 3 页引导走：连接录音笔、选转写服务并填自己的阿里云密钥、设置 WiFi 同步（可选）。
   之后插上 USB 就会自动拷贝新录音，转写成会议纪要。
5. 每次升级后第一次启动，macOS 会询问能否读取钥匙串里的密钥，点「始终允许」。
6. 换电脑：菜单栏图标 →「偏好…」→ 通用 → 导出配置，在新电脑上导入后重新填密钥（密钥不随配置导出）。

项目主页与问题反馈：https://github.com/seabird000/E1Recorder
TXT
hdiutil create -volname "$NAME" -srcfolder "$STAGE" -ov -format UDZO "build/E1Recorder-$VERSION.dmg" >/dev/null
rm -rf "$STAGE"
echo "built: $APP"
echo "built: build/E1Recorder-$VERSION.dmg"
