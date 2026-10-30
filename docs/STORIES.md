# FrameLoop2 stories

Snapshot pages (for `[snap]`): `player-empty`, `player-loaded`, `player-segment`, `sidebar-folders`, `export-progress`, `settings-folders`, `settings-saves`.

## M1 Core loop

### S-001 Open a video from the Open dialog
As the user, I press Command-O, choose a video, and it appears in the player paused on frame 1.
Screens: player-empty, player-loaded
Acceptance:
- [snap] Empty window shows "Open or drop a video" and the supported formats.
- [snap] Loaded window shows the frame, file name in the title, and the transport bar.
- [unit] Frame list for a sample MP4 has the right count and rising timestamps.
Status: done

### S-002 Play and pause
As the user, I press Space to play or pause.
Depends: S-001
Acceptance:
- [self] Space toggles playback; the play button icon matches the state.
- [self] Volume slider changes volume; mute works.
Status: todo

### S-003 Step one frame
As the user, I press Left or Right to step one frame back or forward.
Depends: S-001
Screens: player-loaded
Acceptance:
- [unit] Stepping uses the frame list: Right at the last frame stays; Left at frame 0 stays.
- [self] After a step the displayed frame index and timecode update and match the player time.
- [snap] Frame counter and timecode (mm:ss.mmm) show beside the playhead.
Status: done

### S-004 Scrub the timeline
As the user, I drag the playhead and the picture follows frame-accurately. Buttons jump 10 seconds back and forward.
Depends: S-001
Acceptance:
- [unit] Time to frame lookup snaps to the frame at or before the time.
- [self] Dragging seeks with zero tolerance and lands on exact frames.
Status: done

### S-005 Mark a segment
As the user, I press I and O (or drag the two handles) to set the segment start and end; Reset clears it.
Depends: S-004
Screens: player-segment
Acceptance:
- [snap] The timeline shows the segment as a highlighted range with two handles.
- [unit] End before start wraps around the end of the clip (frame ranges as in the old app).
- [self] Reset removes the segment.
Status: done

### S-006 Loop the segment forward
As the user, I press L and the segment plays on repeat.
Depends: S-005
Acceptance:
- [self] Playback jumps from the end frame to the start frame with no visible stall.
- [self] Without a segment, L loops the whole clip.
Status: done

### S-007 Ping-pong loop
As the user, I turn on "Reverse loop" and the segment plays forward, then backward, then forward.
Depends: S-006
Acceptance:
- [unit] Reverse frame order is 0..n-1 then n-2..1 (same as the old `reverseFrameOrder`).
- [self] The loop alternates direction at the segment ends without building a temporary file.
- [manual] Reversed playback is smooth on H.264 and HEVC clips.
Status: done

### S-008 Change playback speed
As the user, I pick 2×, 1.5×, 1.25×, 1×, 0.75×, 0.5× or 0.25× and playback, loops, and exports use it.
Depends: S-002
Acceptance:
- [unit] Speed list is exactly 2, 1.5, 1.25, 1, 0.75, 0.5, 0.25.
- [self] At 2× playback covers about twice the frames, and a 2× export is half as long.
- [self] Pitch stays natural at reduced speed.
Status: done

### S-009 Mirror the picture
As the user, I flip the video horizontally for viewing, screenshots, and exports.
Depends: S-001
Acceptance:
- [self] The mirror toggle flips the displayed picture; screenshots and exports match it.
Status: done

## M2 Library

### S-010 Folder shortcuts in a sidebar
As the user, I see five folder shortcuts (Movies, Downloads, Desktop, Documents, Pictures) and the videos in the chosen one.
Screens: sidebar-folders
Acceptance:
- [unit] Folder listing keeps only supported extensions and sorts case-insensitively.
- [snap] Sidebar shows the folders and the video list; the open file is highlighted.
Status: done

### S-011 Open a video from the sidebar
As the user, I click a video in the list and it opens in the current window.
Depends: S-010
Acceptance:
- [self] Clicking replaces the open video and resets the segment.
Status: todo

### S-012 Drop a video on the window or Dock icon
As the user, I drag a video onto the window or the Dock icon and it opens.
Depends: S-001
Acceptance:
- [self] Drop on the window opens the file; unsupported files show an error banner.
- [manual] Dock icon drop and Finder "Open With" open a new window.
Status: todo

### S-013 Several windows
As the user, I press Command-N and get a second window with its own video.
Acceptance:
- [self] Two windows play different files independently.
Status: todo

### S-014 Refresh and toggle the folder list
As the user, I refresh the list and hide or show the sidebar.
Depends: S-010
Acceptance:
- [self] Refresh picks up a file added to the folder.
Status: todo

## M3 Export

### S-015 Screenshot the current frame
As the user, I press S and the exact frame is saved as PNG in the screenshot folder as `ssNNNNNNNN.png`.
Depends: S-003, S-009
Acceptance:
- [unit] Next file counter is the max of saved counter and existing files plus 1.
- [self] The PNG matches the displayed frame size, mirrored if mirror is on.
- [snap] A toast confirms the saved file name.
Status: done

### S-016 Export the segment as MP4 (768×512)
As the user, I choose "Export MP4 H.264, 24 FPS, 768x512 (letterboxed)" from the export menu and get `loopNNNNNNNN.mp4` of the segment, honoring speed, mirror, and ping-pong.
Depends: S-007, S-008, S-009
Screens: export-progress
Acceptance:
- [unit] Letterbox rect fits inside 768x512 with black bars and even sizes.
- [self] Output has the right duration and frame rate.
- [snap] A progress sheet shows percent and a Cancel button.
Status: done

### S-017 Export the segment as GIF
As the user, I choose "Export animated GIF, 15 FPS, max 640 px wide" and get a `.gif` in the export folder.
Depends: S-016
Acceptance:
- [self] GIF is 15 fps and at most 640 px wide, loops forever.
Status: done

### S-018 Cancel a running job
As the user, I press Cancel and the export stops and leaves no partial file.
Depends: S-016
Acceptance:
- [self] Cancel removes the unfinished output.
Status: done

## M4 Edit

### S-019 Delete the selection
As the user, I press Delete and the segment is cut out of the clip.
Depends: S-005
Acceptance:
- [unit] Remaining frame ranges for a middle, edge, and wrapped selection are right.
- [self] The player shows the shortened clip; the original file is unchanged.
Status: done

### S-020 Append a video
As the user, I choose Append and add another video to the end.
Depends: S-001
Acceptance:
- [self] The playhead timeline covers both clips; frame stepping crosses the join.
Status: done

### S-021 Undo the last edit
As the user, I press Command-Z to undo the last append or delete.
Depends: S-019
Acceptance:
- [self] One level of undo restores the previous clip and segment.
Status: done

### S-028 Keep the sound in MP4 exports
As the user, I export a segment and the MP4 has the clip's sound, cut to the same frames, reversed on the ping-pong return, and slowed with the picture.
Depends: S-016
Acceptance:
- [unit] Frame order splits into forward and backward audio runs; a wrapped segment splits at the jump.
- [self] The MP4 has an audio track as long as the picture.
- [self] Ping-pong sound rises, then falls back.
- [self] At half speed the sound lasts twice as long and keeps its pitch.
Status: done

## M5 Compatibility

### S-022 Play MKV, AVI, FLV, and AV1 through ffmpeg
As the user, I open a file AVFoundation cannot read and it still plays, after a short "Preparing media" step.
Depends: S-001
Acceptance:
- [unit] Playback plan picks direct, remux, or transcode from stream info.
- [self] An MKV with H.264 remuxes in seconds; an AVI transcodes with progress.
- [self] Without ffmpeg installed, an error banner names what is missing.
Status: done

### S-023 Play HDR video with correct picture
As the user, I open an HLG or PQ clip and it shows with sensible color.
Acceptance:
- [manual] HDR clips are not black.
Status: todo

### S-024 Open GIF files
As the user, I open an animated GIF and step through its frames.
Depends: S-022
Acceptance:
- [self] GIF opens and steps frame by frame.
Status: done

## M6 Polish

### S-025 Settings for folders and save locations
As the user, I edit the five folder shortcuts and the screenshot and export folders in Settings.
Screens: settings-folders, settings-saves
Acceptance:
- [snap] Settings tabs "Folders" and "Saves".
- [unit] Settings survive a restart; counters never go backward.
Status: done

### S-026 Menu commands and shortcuts
As the user, I can do every action from the menu bar with its shortcut shown.
Acceptance:
- [self] Each menu item is enabled only when it can run.
Status: todo

### S-027 App icon and empty states
As the user, I see a proper icon, an empty-folder message, and clear error banners.
Screens: player-empty, sidebar-folders
Acceptance:
- [snap] Folder with no videos shows "No supported videos".
Status: todo

## M7 Viewing and export options

### S-029 Faster playback speeds
As the user, I pick 1.25×, 1.5×, or 2× from the Speed menu (or Control-1 to 7) and the clip plays and exports faster.
Depends: S-008
Acceptance:
- [unit] Speeds list has 2, 1.5, 1.25 above 1; a 2× plan shows every other frame.
- [self] 2× playback covers about twice the frames; a 2× export is half as long.
Status: done

### S-030 Loop is on by default
As the user, I open a video and it loops without my turning Loop on.
Depends: S-006
Acceptance:
- [self] A new player has looping on.
Status: done

### S-031 Export an MP4 at the original size
As the user, I click Export, or press Command-E, and get an MP4 at the clip's own size and frame rate. The arrow next to Export offers the 768×512 MP4 and the GIF.
Depends: S-016
Acceptance:
- [unit] The size is the source size rounded to even; the bit rate grows with the pixel count, within 8 to 55 Mbit/s.
- [self] A 640×360 30 fps clip exports as 640×360 at 30 fps, with the speed and mirror applied.
Status: done

### S-032 Mirror flips the picture left to right
As the user, I turn on Mirror (M) and the picture turns around its vertical centre line: left becomes right and it stays the right way up, in the player, screenshots, and exports.
Depends: S-009
Acceptance:
- [self] The player's frame has the square on the right when mirrored, same size; turning Mirror off clears it.
Status: done

### S-033 Adjust brightness, contrast, saturation, exposure, and hue
As the user, I open the Adjustments panel from the toolbar (Option-Command-A), move the sliders, and see the picture change. Screenshots and exports match. Reset All puts every slider back.
Depends: S-001
Screens: adjust
Acceptance:
- [self] Saturation 0 removes the colour in the player's frame; brightness changes screenshots.
- [snap] The panel opens beside the video with five sliders, their values, and Reset All.
Status: done

### S-034 Show the picture size and frame rate
As the user, I turn on Video Info (Option-Command-I) and the size and frame rate show over the corner of the video. It stays off until I turn it on, and the choice is kept.
Depends: S-001
Screens: info
Acceptance:
- [snap] A dark capsule at the top left reads "640×360 · 30 fps".
Status: done

### S-035 Tooltips on every icon
As the user, I hover over any icon button and see what it does and its shortcut.
Acceptance:
- [manual] Every toolbar item, transport button, segment handle, and the volume control shows a tooltip.
Status: done

## Dropped
- Electron shell, asar packing, single-instance lock: a native app does not need them.
- Bundled GPL ffmpeg build: ffmpeg is optional and read from Homebrew; no redistribution.
- Backup of app.asar versions: git replaces it.

## Known gaps
- S-023 HDR: AVFoundation plays HDR natively; not checked with a real HDR clip.
- S-029..S-033: the player's picture was checked through AVFoundation frames; the live window was not viewed (no Screen Recording permission).
- S-002, S-011..S-014, S-026, S-027 not verified or only partly built (Open With, Dock drop, icon).

## Later
- Per-folder recents, frame-by-frame annotation.
