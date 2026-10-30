#!/bin/zsh
# Runs the in-app self-test against a fresh store in /tmp. Exit code 0 when every check passed.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.robschoen.frameloop2.savedState
store=/tmp/FrameLoop2-self.store
rm -f $store $store-shm $store-wal
APP_STORE=$store ~/Applications/FrameLoop2.app/Contents/MacOS/FrameLoop2 --selftest
