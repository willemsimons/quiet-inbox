#!/bin/zsh
# Build the Inbox Mac app from this checkout and put it in /Applications.
# Needs Xcode and XcodeGen (brew install xcodegen). The app runs inbox.py from this folder, so keep the checkout here.
set -euo pipefail
cd "${0:A:h}"
command -v xcodegen >/dev/null || { echo "Install XcodeGen first: brew install xcodegen"; exit 1; }
xcodegen generate --quiet
xcodebuild -project InboxMac.xcodeproj -scheme Inbox -configuration Release -derivedDataPath build/dd build -quiet
osascript -e 'quit app "Inbox"' 2>/dev/null || true
sleep 1
ditto build/dd/Build/Products/Release/Inbox.app /Applications/Inbox.app
echo "Installed /Applications/Inbox.app"
open /Applications/Inbox.app
