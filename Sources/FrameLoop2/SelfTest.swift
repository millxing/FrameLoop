@preconcurrency import AVFoundation
import AppKit
import FrameLoop2Kit
import ImageIO

/// Self-test for agents: runs the app's real functions on test clips, prints PASS or FAIL per check,
/// and quits with exit code 0 or 1.
///   APP_STORE=/tmp/FrameLoop2-self.store ~/Applications/FrameLoop2.app/Contents/MacOS/FrameLoop2 --selftest
/// (tools/selftest.sh does this.) Add a check for every story with logic.
@MainActor
enum SelfTest {
    static var requested: Bool { CommandLine.arguments.contains("--selftest") }
    /// Read by AppDelegate.applicationWillTerminate.
    static var exitCode: Int32 = 0
    private static var failures = 0
    private static var count = 0
    private static var started = false

    static func runIfRequested(model: PlayerModel, library: Library) {
        guard requested, !started else { return }
        started = true
        // Print each line at once, so a crash keeps the lines before it.
        setvbuf(stdout, nil, _IOLBF, 0)
        guard Store.isOverridden else {
            print("SELFTEST refused: set APP_STORE to a file in /tmp")
            finish(code: 1)
            return
        }
        Task {
            do { try await run(model: model, library: library) } catch { check("self-test ran to the end", false, "\(error)") }
            print(failures == 0 ? "SELFTEST PASS \(count) checks" : "SELFTEST FAIL \(failures) of \(count) checks")
            finish(code: failures == 0 ? 0 : 1)
        }
    }

    private static func run(model: PlayerModel, library: Library) async throws {
        try? FileManager.default.removeItem(at: Store.scratch)
        let sample = try await SampleVideo.prepare()

        // S-001 open
        await model.open(sample)
        check("S-001 opening a clip loads 90 frames", model.video?.frames.count == 90, "\(model.video?.frames.count ?? -1)")
        check("S-001 size and frame rate are read", model.video?.width == 640 && model.video?.height == 360 && abs((model.video?.frameRate ?? 0) - 30) < 0.01)
        check("S-001 timestamps rise", zip(model.video!.frames, model.video!.frames.dropFirst()).allSatisfy { $0.pts < $1.pts })
        await library.refresh()
        check("S-010 the folder list shows both sample clips", library.files.map(\.lastPathComponent) == ["bouncing-square.mp4", "short-clip.mp4"], "\(library.files.map(\.lastPathComponent))")

        // S-003 / S-004 stepping and seeking land on exact frames
        model.step(by: 1)
        check("S-003 step forward moves one frame", model.currentFrame == 1)
        model.step(by: -5)
        check("S-003 step back stops at frame 0", model.currentFrame == 0)
        model.seek(toFrame: 10)
        try await Task.sleep(for: .seconds(0.4))
        check("S-004 seek shows the exact frame", Timeline.frameAtTime(model.video!.frames, time: model.player.currentTime().seconds) == 10,
              "player at \(model.player.currentTime().seconds)")

        // S-005 segment
        model.markStart()
        model.seek(toFrame: 30)
        model.markEnd()
        check("S-005 marks a segment", model.segment == Segment(startFrame: 10, endFrame: 30))
        check("S-005 export order covers the segment", model.exportOrder().count == 21)
        model.pingPong = true
        check("S-007 reverse loop adds the way back", model.exportOrder().count == 40)
        model.pingPong = false

        // S-006 forward loop stays inside the segment and wraps
        model.loopEnabled = true
        model.seek(toFrame: 10)
        model.play()
        var seen: [Int] = []
        for _ in 0..<75 {
            try await Task.sleep(for: .milliseconds(20))
            seen.append(model.currentFrame)
        }
        model.pause()
        check("S-006 loop never leaves the segment", seen.allSatisfy { (9...31).contains($0) }, "\(Set(seen.filter { !(9...31).contains($0) }))")
        let wrapped = zip(seen, seen.dropFirst()).contains { $0 > 25 && $1 < 15 }
        check("S-006 loop jumps back to the start", wrapped, "frames \(seen.min() ?? -1)...\(seen.max() ?? -1)")

        // S-007 ping-pong turns around
        model.pingPong = true
        model.seek(toFrame: 10)
        model.play()
        var sawBackward = false
        var pingPongFrames: [Int] = []
        for _ in 0..<110 {
            try await Task.sleep(for: .milliseconds(20))
            pingPongFrames.append(model.currentFrame)
            if model.direction == .backward { sawBackward = true }
        }
        model.pause()
        check("S-007 ping-pong plays backward", sawBackward)
        check("S-007 ping-pong stays inside the segment", pingPongFrames.allSatisfy { (9...31).contains($0) }, "\(pingPongFrames.min() ?? -1)...\(pingPongFrames.max() ?? -1)")
        model.pingPong = false
        model.loopEnabled = false

        // S-008 speed
        model.speed = 0.5
        model.seek(toFrame: 0)
        model.play()
        try await Task.sleep(for: .seconds(1))
        model.pause()
        check("S-008 half speed plays about half as far", (8...22).contains(model.currentFrame), "frame \(model.currentFrame)")
        model.speed = 1

        // S-015 screenshots, S-009 mirror
        model.seek(toFrame: 0)
        try await Task.sleep(for: .seconds(0.3))
        model.saveScreenshot()
        try await waitForToast(model)
        let shot = model.toast?.url
        check("S-015 screenshot is named ss00000001.png", shot?.lastPathComponent == "ss00000001.png", "\(shot?.lastPathComponent ?? "none")")
        if let shot, let (w, h, left, right) = yellowSides(shot) {
            check("S-015 screenshot is 640×360", w == 640 && h == 360)
            check("S-015 the square is on the left", left && !right)
        } else { check("S-015 screenshot can be read", false) }
        model.toast = nil
        model.mirrored = true
        model.saveScreenshot()
        try await waitForToast(model)
        if let shot = model.toast?.url, let (_, _, left, right) = yellowSides(shot) {
            check("S-009 mirrored screenshot flips the picture", right && !left)
            check("S-015 second screenshot is numbered 2", shot.lastPathComponent == "ss00000002.png")
        } else { check("S-009 mirrored screenshot can be read", false) }
        model.toast = nil
        model.mirrored = false

        // S-016 MP4: segment 10...30 at 24 fps from 30 fps source
        model.export(.mp4)
        await model.waitForJob()
        if let url = model.toast?.url {
            let asset = AVURLAsset(url: url)
            let track = try await asset.loadTracks(withMediaType: .video).first
            let size = try await track?.load(.naturalSize)
            let duration = try await asset.load(.duration).seconds
            check("S-016 MP4 is 768×512", size == CGSize(width: 768, height: 512), "\(String(describing: size))")
            check("S-016 MP4 lasts as long as the segment", abs(duration - 21.0 / 30.0) < 0.1, "\(duration)")
            check("S-016 MP4 is named loop00000001.mp4", url.lastPathComponent == "loop00000001.mp4")
        } else { check("S-016 MP4 export finished", false, model.message ?? "no file") }
        model.toast = nil

        // S-017 GIF
        model.export(.gif)
        await model.waitForJob()
        if let url = model.toast?.url, let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let frames = CGImageSourceGetCount(source)
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
            check("S-017 GIF has the right frame count", abs(frames - 11) <= 1, "\(frames)")
            check("S-017 GIF is 640 wide at most", (image?.width ?? 9999) <= 640)
        } else { check("S-017 GIF export finished", false, model.message ?? "no file") }
        model.toast = nil

        // S-018 cancel leaves nothing behind
        let before = (try? FileManager.default.contentsOfDirectory(atPath: AppSettings.shared.exportDirectory))?.count ?? 0
        model.segment = nil
        model.export(.mp4)
        model.cancelJob()
        await model.waitForJob()
        let after = (try? FileManager.default.contentsOfDirectory(atPath: AppSettings.shared.exportDirectory))?.count ?? 0
        check("S-018 cancelling an export leaves no partial file", after == before, "\(before) -> \(after)")
        check("S-018 the job is cleared", model.job == nil)

        try await editChecks(model: model, sample: sample)
        try await compatibilityChecks(model: model, sample: sample)
    }

    private static func editChecks(model: PlayerModel, sample: URL) async throws {
        let short = sample.deletingLastPathComponent().appending(path: "short-clip.mp4")
        await model.open(sample)
        let before = try FileManager.default.attributesOfItem(atPath: sample.path)

        // S-019 delete
        model.setSegmentStart(frame: 10)
        model.setSegmentEnd(frame: 29)
        check("S-019 delete is enabled with a segment", model.canDelete)
        await model.deleteSelection()
        let frames = model.video?.frames ?? []
        check("S-019 deleting 20 frames leaves 70", frames.count == 70, "\(frames.count)")
        let gaps = zip(frames, frames.dropFirst()).map { $1.pts - $0.pts }
        check("S-019 the cut leaves no gap or jump", gaps.allSatisfy { abs($0 - 1.0 / 30) < 0.002 }, "\(gaps.min() ?? 0)...\(gaps.max() ?? 0)")
        let after = try FileManager.default.attributesOfItem(atPath: sample.path)
        check("S-019 the original file is untouched", (before[.size] as? Int) == (after[.size] as? Int) && (before[.modificationDate] as? Date) == (after[.modificationDate] as? Date))
        let playerDuration = (try await model.player.currentItem?.asset.load(.duration))?.seconds ?? 0
        check("S-019 the player plays the shortened clip", abs(playerDuration - 70.0 / 30) < 0.1, "\(playerDuration)")
        check("S-019 the segment is cleared after a cut", model.segment == nil)

        // S-021 undo
        check("S-021 undo is enabled after an edit", model.canUndo)
        model.undoEdit()
        check("S-021 undo restores all 90 frames", model.video?.frames.count == 90, "\(model.video?.frames.count ?? -1)")
        check("S-021 undo is disabled with nothing to undo", !model.canUndo)

        // S-019 delete a segment that wraps around the end of the clip
        model.setSegmentStart(frame: 80)
        model.setSegmentEnd(frame: 5)
        await model.deleteSelection()
        check("S-019 a wrapped segment removes both ends", model.video?.frames.count == 74, "\(model.video?.frames.count ?? -1)")
        model.undoEdit()

        // S-020 append a clip of another size and frame rate
        await model.append(short)
        check("S-020 appending adds the frames", model.video?.frames.count == 138, "\(model.video?.frames.count ?? -1)")
        check("S-020 the picture size stays the first clip's", model.video?.width == 640 && model.video?.height == 360, "\(model.video?.width ?? 0)x\(model.video?.height ?? 0)")
        model.seek(toFrame: 89)
        model.step(by: 1)
        try await Task.sleep(for: .seconds(0.4))
        check("S-020 stepping crosses the join", model.currentFrame == 90 && Timeline.frameAtTime(model.video!.frames, time: model.player.currentTime().seconds) == 90)
        model.segment = nil
        model.export(.mp4)
        await model.waitForJob()
        if let url = model.toast?.url {
            let asset = AVURLAsset(url: url)
            let duration = try await asset.load(.duration).seconds
            check("S-020 the joined clip exports in full", abs(duration - 5.0) < 0.2, "\(duration)")
        } else { check("S-020 the joined clip exports", false, model.message ?? "no file") }
        model.toast = nil
        model.undoEdit()
        check("S-021 undo removes the appended clip", model.video?.frames.count == 90)
    }

    private static func compatibilityChecks(model: PlayerModel, sample: URL) async throws {
        guard let ffmpeg = FFmpeg.tool("ffmpeg") else {
            print("SKIP S-022 ffmpeg is not installed")
            return
        }
        let folder = sample.deletingLastPathComponent()
        func make(_ name: String, _ args: [String]) -> URL {
            let output = folder.appending(path: name)
            let process = Process()
            process.executableURL = ffmpeg
            process.arguments = ["-y", "-v", "error", "-i", sample.path] + args + [output.path]
            try? process.run()
            process.waitUntilExit()
            return output
        }
        let mkv = make("clip.mkv", ["-c", "copy"])
        let avi = make("clip.avi", ["-c:v", "mpeg4", "-q:v", "2"])
        let gif = make("clip.gif", ["-vf", "fps=15,scale=320:-1"])

        let start = Date()
        await model.open(mkv)
        check("S-022 an MKV opens by remuxing", model.video?.frames.count == 90, "\(model.video?.frames.count ?? -1) \(model.message ?? "")")
        check("S-022 the remux is quick", Date().timeIntervalSince(start) < 8, "\(Date().timeIntervalSince(start)) s")
        check("S-022 the title still names the MKV", model.video?.url.lastPathComponent == "clip.mkv")
        model.step(by: 5)
        try await Task.sleep(for: .seconds(0.3))
        check("S-022 frame stepping works on the copy", model.currentFrame == 5)

        await model.open(avi)
        check("S-022 an AVI opens by transcoding", model.video?.frames.count == 90, "\(model.video?.frames.count ?? -1) \(model.message ?? "")")

        await model.open(gif)
        check("S-024 a GIF opens and has its frames", (model.video?.frames.count ?? 0) >= 40, "\(model.video?.frames.count ?? -1) \(model.message ?? "")")

        await model.open(sample)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: FFmpeg.directory.path))?.count ?? 0
        check("S-022 temporary copies are deleted when the video is replaced", leftovers == 0, "\(leftovers) left")
    }

    private static func waitForToast(_ model: PlayerModel) async throws {
        for _ in 0..<150 {
            if model.toast != nil { return }
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Whether a yellow pixel sits in the left or right third of the image's middle row.
    private static func yellowSides(_ url: URL) -> (Int, Int, Bool, Bool)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = { context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height)); return context.data }()
        else { return nil }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let row = image.height / 2
        func yellow(_ x: Int) -> Bool {
            let offset = row * context.bytesPerRow + x * 4
            return pixels[offset] > 200 && pixels[offset + 1] > 150 && pixels[offset + 2] < 120
        }
        let third = image.width / 3
        return (image.width, image.height, (0..<third).contains { yellow($0) }, ((image.width - third)..<image.width).contains { yellow($0) })
    }

    private static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        count += 1
        if !ok { failures += 1 }
        print(ok ? "PASS \(name)" : "FAIL \(name)\(detail.isEmpty ? "" : ": \(detail)")")
    }

    /// Quits through NSApp.terminate, never exit(), and closes sheets first:
    /// an open sheet refuses terminate, and the run would wait forever.
    static func finish(code: Int32) {
        exitCode = code
        for window in NSApp.windows { if let sheet = window.attachedSheet { window.endSheet(sheet) } }
        NSApp.terminate(nil)
    }
}
