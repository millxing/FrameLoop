#!/bin/zsh
# Runs the in-app self-test against test data in /tmp. Exit code 0 when every check passed.
# Launches through LaunchServices (open): a binary started straight from a shell can come up with no window.
set -u
rm -rf ~/Library/Saved\ Application\ State/com.robschoen.frameloop2.savedState
log=/tmp/FrameLoop-self.log
: > $log
open -W -n --env APP_STORE=/tmp/FrameLoop-self.store --stdout $log --stderr $log /Applications/FrameLoop.app --args --selftest
cat $log
grep -q "^SELFTEST PASS" $log
