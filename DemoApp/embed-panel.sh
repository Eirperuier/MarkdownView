#!/bin/zsh
# Puts floo-browser's step window in the Mac app, at Contents/PlugIns/FlooEnginePanel.bundle:
# the window a step an agent hands you opens in, showing just the engine page it's on
# (FlooStepPanel.swift). It's AppKit, which a Mac Catalyst app can't link, so it's built as
# a macOS dynamic library from floo-browser (FlooBrowserKit's FlooEnginePanelPlugin) and
# wrapped as a bundle the app loads at runtime. floo-browser has to be beside this
# repository, or named by FLOO_BROWSER. Not on iOS.
set -euo pipefail
[[ ${IS_MACCATALYST:-NO} == YES ]] || exit 0
browser=${FLOO_BROWSER:-$SRCROOT/../../floo-browser}
kit=$browser/LocalPackages/FlooBrowserKit
if [[ ! -f $kit/Package.swift ]]; then
  print "error: the step window is built from floo-browser, which isn't beside this repository ($browser)"
  exit 1
fi
configuration=debug
[[ $CONFIGURATION == Release ]] && configuration=release
# A build of its own, in its own folder: none of this build's settings go with it.
# SwiftUI weakly: the engine's view code carries AppKit SwiftUI views it never makes here
# (NSViewRepresentable and the like), which the SwiftUI a Catalyst app runs doesn't have;
# linked strongly, the bundle doesn't load ("Symbol not found").
built=$DERIVED_FILE_DIR/floo-engine-panel
env -i HOME=$HOME USER=$USER PATH=/usr/bin:/bin:/usr/sbin:/sbin DEVELOPER_DIR=$DEVELOPER_DIR \
  /usr/bin/swift build --package-path $kit --scratch-path $built -c $configuration --product FlooEnginePanelPlugin \
  -Xlinker -weak_framework -Xlinker SwiftUI
bundle=$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/PlugIns/FlooEnginePanel.bundle
rm -rf $bundle
mkdir -p $bundle/Contents/MacOS
cp $built/$configuration/libFlooEnginePanelPlugin.dylib $bundle/Contents/MacOS/FlooEnginePanel
cat > $bundle/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>dev.floo.app.engine-panel</string>
  <key>CFBundleName</key><string>FlooEnginePanel</string>
  <key>CFBundleExecutable</key><string>FlooEnginePanel</string>
  <key>CFBundlePackageType</key><string>BNDL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>NSPrincipalClass</key><string>FlooEnginePanelPlugin</string>
</dict>
</plist>
PLIST
# Signed before the app is, with the app's identity (ad hoc when it has none): the app's
# signature seals what it carries.
codesign --force --sign ${EXPANDED_CODE_SIGN_IDENTITY:--} --timestamp=none $bundle
