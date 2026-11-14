#!/bin/zsh
# Build TileSpace.app (and the tilespace command) into build/.
#   scripts/build-app.sh            build
#   scripts/build-app.sh --install  also copy the app to ~/Applications and tilespace to ~/.local/bin,
#                                   replacing (and restarting) any copy already there
#
# Signs with your Apple Development certificate (override with SIGN_IDENTITY) so the
# Accessibility permission survives rebuilds; an ad-hoc signature would need it granted again
# after every build.
set -euo pipefail
cd "${0:A:h}/.."

swift build -c release
app=build/TileSpace.app
rm -rf $app
mkdir -p $app/Contents/MacOS
cp .build/release/TileSpaceApp $app/Contents/MacOS/TileSpace
cp .build/release/tilespace build/tilespace
cat > $app/Contents/Info.plist <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.trevinlee.tilespace</string>
    <key>CFBundleName</key><string>TileSpace</string>
    <key>CFBundleExecutable</key><string>TileSpace</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>com.trevinlee.tilespace</string>
        <key>CFBundleURLSchemes</key><array><string>tilespace</string></array>
    </dict></array>
</dict>
</plist>
EOF

identity=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')}
codesign --force --options runtime --sign "${identity:--}" $app
codesign --force --sign "${identity:--}" build/tilespace
echo "built $app (signed by ${identity:-ad hoc})"

if [[ ${1:-} == --install ]]; then
    pkill -x TileSpace && while pgrep -x TileSpace >/dev/null; do sleep 0.1; done
    mkdir -p ~/Applications ~/.local/bin
    rm -rf ~/Applications/TileSpace.app
    cp -R $app ~/Applications/
    cp build/tilespace ~/.local/bin/tilespace
    open ~/Applications/TileSpace.app
    echo "installed ~/Applications/TileSpace.app and ~/.local/bin/tilespace"
    if [[ ":$PATH:" != *":$HOME/.local/bin:"* ]]; then
        echo "~/.local/bin isn't on your PATH; to run tilespace by name, add it:"
        echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
    fi
fi
