#!/bin/zsh
# Snapshots of every page in light and dark, with sample clips, on test data in /tmp.
# Usage: tools/snap.sh            all pages
#        APP_SNAPSHOT_PAGES=loaded,settings tools/snap.sh
# Launches through LaunchServices (open): a binary started straight from a shell can come up with no window.
set -u
shots=/tmp/FrameLoop-shots
log=/tmp/FrameLoop-snap.log
# A crashed run leaves saved window state, and the next launch would wait on a "reopen windows?" alert.
rm -rf ~/Library/Saved\ Application\ State/com.robschoen.frameloop2.savedState
rm -rf $shots
: > $log
open -W -n --env APP_STORE=/tmp/FrameLoop-snap.store --env APP_SNAPSHOT=$shots --env APP_SNAPSHOT_PAGES="${APP_SNAPSHOT_PAGES:-empty,loaded,mirror,info,adjust,segment,export,settings}" --stdout $log --stderr $log /Applications/FrameLoop.app
cat $log
