#!/bin/zsh
# Builds build/Spectrum.app (release). Uses Xcode's toolchain when its license is accepted,
# otherwise the command-line tools plus Xcode's SwiftUI macro plugins.
set -euo pipefail
root=${0:A:h:h}
cd $root
./scripts/gen_shaders.sh

xcode=/Applications/Xcode.app/Contents/Developer
flags=()
if DEVELOPER_DIR=$xcode xcrun --find metal >/dev/null 2>&1; then
  export DEVELOPER_DIR=$xcode
elif [[ -d $xcode ]]; then
  flags=(-Xswiftc -plugin-path -Xswiftc $xcode/Platforms/MacOSX.platform/Developer/usr/lib/swift/host/plugins)
fi
swift build -c release --product FractalSpectrum $flags 2>&1 | grep -vE "ld: warning|was built for newer" || true
bin=$(swift build -c release --show-bin-path $flags)/FractalSpectrum
[[ -x $bin ]] || { echo "build failed"; exit 1; }

app=$root/build/Spectrum.app
rm -rf $app
mkdir -p $app/Contents/MacOS $app/Contents/Resources
cp $bin $app/Contents/MacOS/Spectrum
[[ -f $root/Resources/AppIcon.icns ]] && cp $root/Resources/AppIcon.icns $app/Contents/Resources/
cat > $app/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Spectrum</string>
  <key>CFBundleDisplayName</key><string>Spectrum</string>
  <key>CFBundleIdentifier</key><string>com.lpalm.spectrum</string>
  <key>CFBundleExecutable</key><string>Spectrum</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.graphics-design</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - $app >/dev/null 2>&1
echo "built $app"
