# Sign and notarize FrameLoop

The native project is in `~/Developer/FrameLoop`. The project in
`~/Dropbox/CC/FrameLoop` is the old Electron app.

Run from the native project:

```sh
bash scripts/release.sh
```

This signs a copy of `/Applications/FrameLoop.app`. It does not rebuild it
or replace the installed app. To release a new source build, run `./build.sh`
first with the Xcode toolchain described in `CLAUDE.md`. You can also pass
another native app bundle as the script's first argument.

The script uses the same Developer ID certificate and `framedl-notary`
Keychain profile as FrameDL. Credentials stay in Keychain. Override these
with `SIGN_IDENTITY` and `NOTARY_PROFILE` if needed.

The script enables Hardened Runtime, notarizes and staples the app, makes
a signed DMG, then notarizes and staples the DMG. Both must pass Gatekeeper.
No extra entitlements are required by this native build.

Outputs are in `releases/FrameLoop-<version>-<build>-<architecture>/`:

- `FrameLoop.app`: signed app with Apple's ticket attached.
- `FrameLoop-<version>-<architecture>.dmg`: installer to share.
- Submission records and Apple scan logs for the app and DMG.
- `SHA256SUMS.txt`: installer checksum.

Existing release folders are never overwritten. If a submission is interrupted,
use its saved ID with `xcrun notarytool info` or `wait`, with
`--keychain-profile framedl-notary`. Keep that output until the submission is
resolved. A fresh full run requires a new build number or moving the previous
release folder elsewhere.

To install, open the DMG, quit FrameLoop, then drag it to Applications.
Running `./build.sh` again replaces the installed app with a development build;
run the release script again before sharing that build.
