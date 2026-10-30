# FrameLoop2

A native Mac video player for stepping through footage frame by frame, looping a chosen segment (forward or ping-pong), and exporting stills, clips, and GIFs. For one person who studies and clips video.

## Replaces
FrameLoop (Electron, React, ffmpeg). Decided by the agent: same jobs, rebuilt native so it opens fast, uses little memory, and looks like a Mac app.

## Main jobs
1. Open a video (Open, drop, Finder "Open With", or pick from a folder shortcut) and scrub or step it frame by frame.
2. Mark a segment (start, end) and loop it forward or ping-pong (reverse loop), at 1x, 0.75x, 0.5x, 0.25x.
3. Export: PNG screenshot of the current frame, MP4 of the segment (H.264, 24 fps, 768x512 letterboxed), or animated GIF (15 fps, max 640 px wide). Files are auto-numbered (`ss00000001.png`, `loop00000001.mp4`).
4. Edit the clip: delete the selection, append another video, undo.

## Data
- Settings only, no database: five folder shortcuts (default Movies, Downloads, Desktop, Documents, Pictures), screenshot folder, export folder, running file counters.
- Open media is a file on disk. Frame times come from the asset's track, not a stored copy.

## Shape
Document-style window, one per video, macOS 26 or later. Sidebar of folder shortcuts and their videos (toggleable), player in the detail pane, transport bar and segment timeline below. Native AVFoundation playback. Falls back to ffmpeg (if installed) only for containers or codecs AVFoundation cannot read (MKV, AVI, FLV, AV1). Local data. Works offline. No accounts.

## System hooks
Finder "Open With" and drag onto the Dock icon for MP4, M4V, MOV, MKV, AVI, FLV, GIF. Keyboard: arrows step frames, space plays, I/O set segment, L loops. Menu bar commands for every action. No global shortcut, no CLI.

## Reference
Old FrameLoop (behavior). Native look: QuickTime Player and Photos.

## Look
Native with the system accent color, dark-leaning player surface, Liquid Glass transport bar. Decided by the agent: restrained, no custom chrome.

## Not in version one
- Timeline editing beyond delete-selection, append, undo.
- Audio export, subtitles, filters.
- iCloud sync or any network feature.
