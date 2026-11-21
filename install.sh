#!/bin/sh
# Builds the app, copies it to ~/Applications, starts it and registers it as a login item.
set -eu
cd "$(dirname "$0")"
./build.sh
LABEL=org.anybyte.miclock
APP="$HOME/Applications/MicLock.app"

# MicLock before 1.0 started from a LaunchAgent; the app now registers itself as a login item.
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
osascript -e "tell application id \"$LABEL\" to quit" 2>/dev/null || true
sleep 1
pkill -x MicLock 2>/dev/null || true

mkdir -p "$HOME/Applications"
rm -rf "$APP"
ditto build.noindex/MicLock.app "$APP"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP"
open -g "$APP" --args --enable-login-item
echo "installed $APP"
