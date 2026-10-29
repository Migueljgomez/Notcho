#!/bin/zsh
# Builds Notcho.app (a bundle is needed for the calendar permission prompt).
set -e
cd "${0:A:h}"
swift build -c release
APP=/Applications/Notcho.app # in Applications so it shows in Launchpad
rm -rf $APP && mkdir -p $APP/Contents/MacOS
cp .build/release/Notcho $APP/Contents/MacOS/
mkdir -p $APP/Contents/Resources && cp Icon/AppIcon.icns $APP/Contents/Resources/
cat > $APP/Contents/Info.plist <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>app.notcho</string>
  <key>CFBundleName</key><string>Notcho</string>
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
ID=$(security find-identity -p codesigning | awk '/NotchSample Local Signing/ {print $2; exit}')
xattr -cr $APP # Finder/copy metadata makes codesign refuse
codesign --force --sign "${ID:--}" $APP
echo "Built $APP"
