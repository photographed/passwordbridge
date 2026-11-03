#!/bin/zsh
set -eu
cd "${0:A:h}"
TASK_CACHE="${TMPDIR:-/tmp}/passwordbridge-build-cache"
mkdir -p "$TASK_CACHE/clang" "$TASK_CACHE/swift" "$TASK_CACHE/spm"
export CLANG_MODULE_CACHE_PATH="$TASK_CACHE/clang"
export SWIFTPM_MODULECACHE_OVERRIDE="$TASK_CACHE/swift"
swift build --disable-sandbox --cache-path "$TASK_CACHE/spm" -c release
APP="${BRIDGE_APP_NAME:-Password Bridge.app}"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/PasswordBridge "$APP/Contents/MacOS/PasswordBridge"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>PasswordBridge</string>
<key>CFBundleIdentifier</key><string>local.passwordbridge.app</string>
<key>CFBundleName</key><string>Password Bridge</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.5</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
print "作成完了: $PWD/$APP"
