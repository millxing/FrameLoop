# FrameLoop

**Find the moment. Shape the loop. Keep every frame.**

FrameLoop is a native Mac video player for people who want to look closer. Study a movement, build a visual loop, or capture the exact frame you need. Go from a local video to an MP4, animated GIF, or PNG without opening a full video editor.

Made for motion studies, sports footage, animation reference, and visual experiments.

## Small moments, precise control

Step forward or back one frame at a time. Mark a start and end, then watch that section repeat. Slow playback to a quarter speed to inspect a movement, or choose a faster speed to review footage.

A loop can cross the end of the source clip. Mark its start near the end and its finish near the beginning: FrameLoop joins those sections into one loop.

## Forward. Backward. Repeat.

Turn on **Reverse Loop** to play a segment forward, then backward. Export that motion as a clip or GIF. MP4 exports can include sound that follows the loop, including reversed audio on the return pass.

Speed changes carry through to exports. Slower audio keeps its pitch.

## Shape the picture, then save it

Mirror the image and adjust brightness, contrast, saturation, exposure, and hue. Your screenshots and exports use those changes too.

- **Capture a frame** as a PNG.
- **Export an MP4** at the source size and frame rate.
- **Make an animated GIF** for a short, repeating moment.
- **Use a fixed-size MP4 preset** for 768 × 512 output at 24 fps.

Files receive automatic numbers, so you can keep exploring without naming every capture. Remove a selected section, append another video, or undo the last edit. Your original files stay unchanged.

## Give small footage more room

Export at twice the source width and height with Apple's on-device machine-learning video upscaler. Choose **Best Quality** or **Faster but Softer**. Mirror and picture adjustments remain part of the result.

Upscaling requires supported hardware and accepts source video up to 1920 × 1080. Apple’s model downloads on first use. The video processing runs on your Mac.

## At home on the Mac

FrameLoop uses SwiftUI and AVFoundation, with native windows, menus, keyboard shortcuts, and full-screen playback. Folder shortcuts keep local clips close at hand. Choose a light, dark, or system appearance.

No account. No video uploads. Your footage stays local.

## Start with a clip

1. Open a video with **Command-O**.
2. Use **Left** and **Right** to find the frames you want.
3. Press **I** and **O** to mark the loop.
4. Press **Space** to play, or **S** to save the current frame.
5. Press **Command-E** to export an MP4. Use the export menu for GIF and upscaling options.

**Requirements:** macOS 26 or later. The current packaged build is for Apple Silicon. MP4, M4V, and MOV use native playback when their codecs are supported. Optional [FFmpeg](https://ffmpeg.org/) support adds preparation for formats such as MKV, AVI, FLV, and GIF. FFmpeg is not bundled.

## Project status

FrameLoop is an early release. The current Apple Silicon app and DMG have passed Apple notarization and Gatekeeper checks.

One playback timing check remains unresolved: in two signed-app test runs, 2× playback reached frame 27 after 0.6 seconds; the test expects frames 28–50. The other 120 checks passed. The original development build passed all 121 checks. The cause has not been established.

## Build and release

For development, use Xcode with Swift 6.2 and the macOS 26 SDK:

```sh
git clone https://github.com/millxing/FrameLoop.git
cd FrameLoop
./build.sh
```

The build command installs a development copy in `/Applications/FrameLoop.app`, replacing any existing copy. Set `DEVELOPER_DIR` if Xcode is not your active developer toolchain.

See [the release guide](docs/RELEASING.md) for signing and notarization, and [the feature backlog](docs/STORIES.md) for test coverage and known gaps.
