#!/bin/zsh
# Builds Notcho.app (a bundle is needed for the calendar permission prompt).
#   ./make-app.sh          this Mac's chip, installed to /Applications
#   ./make-app.sh release  Apple silicon + Intel, to dist/Notcho.app and dist/Notcho.zip
set -e
cd "${0:A:h}"
VERSION=1.0
if [[ $1 == release ]]; then
  swift build -c release --triple arm64-apple-macosx14.0
  swift build -c release --triple x86_64-apple-macosx14.0
  APP=dist/Notcho.app
  rm -rf dist && mkdir -p $APP/Contents/MacOS
  lipo -create .build/arm64-apple-macosx/release/Notcho .build/x86_64-apple-macosx/release/Notcho -output $APP/Contents/MacOS/Notcho
else
  swift build -c release
  APP=/Applications/Notcho.app # in Applications so it shows in Launchpad
  rm -rf $APP && mkdir -p $APP/Contents/MacOS
  cp .build/release/Notcho $APP/Contents/MacOS/
fi
mkdir -p $APP/Contents/Resources && cp Icon/AppIcon.icns Resources/*.png $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.notcho</string>
  <key>CFBundleName</key><string>Notcho</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleExecutable</key><string>Notcho</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCalendarsFullAccessUsageDescription</key><string>Shows your upcoming events in the notch.</string>
  <key>NSRemindersFullAccessUsageDescription</key><string>Syncs your notch tasks with a "Notch" list in Reminders, so they reach your iPhone.</string>
  <key>CFBundleURLTypes</key><array><dict>
    <key>CFBundleURLName</key><string>app.notcho</string>
    <key>CFBundleURLSchemes</key><array><string>notcho</string><string>notch</string></array>
  </dict></array>
</dict></plist>
PLIST
# A stable identity keeps Reminders/Calendar permissions across rebuilds; ad-hoc (-) changes every build.
# Set NOTCHO_SIGN to your own code-signing certificate's name; without one, builds are signed ad-hoc.
ID=$(security find-identity -p codesigning | awk -v n="${NOTCHO_SIGN:-NotchSample Local Signing}" 'index($0, n) {print $2; exit}')
[[ $1 == release ]] && ID=- # the download is ad-hoc signed: it opens with System Settings → Open Anyway
xattr -cr $APP # Finder/copy metadata makes codesign refuse
codesign --force --sign "${ID:--}" $APP
if [[ $1 == release ]]; then
  ditto -c -k --keepParent $APP dist/Notcho.zip
  echo "Built $APP and dist/Notcho.zip ($(lipo -archs $APP/Contents/MacOS/Notcho))"
else
  echo "Built $APP"
fi
