@preconcurrency import AVFoundation
import AppKit
import FrameLoop2Kit
import Observation
import SwiftUI

/// One window's player: the open video, where it is, the marked segment, and the loop settings.
@Observable
final class PlayerModel {
    struct Job: Equatable {
        var title: String
        var fraction: Double
    }

    struct Toast: Equatable, Identifiable {
        let id = UUID()
        var text: String
        var url: URL?
    }

    private(set) var video: LoadedVideo?
    @ObservationIgnored let player = AVPlayer()
    private(set) var currentFrame = 0
    private(set) var isPlaying = false
    private(set) var isLoading = false
    private(set) var direction = PlayDirection.forward
    private(set) var job: Job?
    var volume: Float = 1 { didSet { player.volume = volume } }
    var speed = 1.0 { didSet { if isPlaying { applyRate() } } }
    var mirrored = false { didSet { refreshLook() } }
    var adjustments = Adjustments() { didSet { refreshLook() } }
    var showAdjustments = false
    /// Whether the sidebar shows. It steps aside when the first video loads and returns when the video closes.
    var columns = NavigationSplitViewVisibility.all
    /// The window is full screen: just the video, with the controls fading in when the pointer moves.
    var fullScreen = false {
        didSet {
            guard fullScreen != oldValue else { return }
            if fullScreen {
                adjustmentsBeforeFullScreen = showAdjustments
                columnsBeforeFullScreen = columns
                showAdjustments = false
                columns = .detailOnly
            } else {
                showAdjustments = adjustmentsBeforeFullScreen
                columns = columnsBeforeFullScreen
            }
        }
    }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var adjustmentsBeforeFullScreen = false
    @ObservationIgnored private var columnsBeforeFullScreen = NavigationSplitViewVisibility.all
    /// Shows the picture size and frame rate over the video. Remembered between launches.
    var showInfo = Store.isOverridden ? false : UserDefaults.standard.bool(forKey: "showVideoInfo") {
        didSet { if !Store.isOverridden { UserDefaults.standard.set(showInfo, forKey: "showVideoInfo") } }
    }
    var segment: Segment?
    var loopEnabled = true
    var pingPong = false
    var message: String?
    var toast: Toast?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var jumping = false
    @ObservationIgnored private var scrubbingWasPlaying: Bool?
    @ObservationIgnored private var reverseTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<LoadedVideo, Error>?
    @ObservationIgnored private var lookTask: Task<Void, Never>?
    @ObservationIgnored private var undoStack: [LoadedVideo] = []

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 120), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
    }

    var canFullScreen: Bool { video != nil }

    func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    // MARK: Opening

    func open(_ url: URL) async {
        guard MediaFormats.isSupported(url) else {
            message = "FrameLoop2 supports \(MediaFormats.supported.map { $0.uppercased() }.joined(separator: ", ")) files."
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(url.lastPathComponent) no longer exists."
            return
        }
        pause()
        guard let loaded = await loadVideo(url) else { return }
        discardProxies()
        undoStack = []
        install(loaded)
    }

    /// Loads a file, first making a playable copy with ffmpeg when AVFoundation cannot read it.
    private func loadVideo(_ url: URL) async -> LoadedVideo? {
        isLoading = true
        defer {
            isLoading = false
            job = nil
            loadTask = nil
        }
        let task = Task { () throws -> LoadedVideo in
            if MediaFormats.isNative(url) {
                let asset = AVURLAsset(url: url)
                if try await asset.load(.isPlayable) { return try await MediaLoader.load(asset: asset, url: url) }
            }
            await MainActor.run { job = Job(title: "Preparing media…", fraction: 0) }
            let report: @Sendable (Double) -> Void = { [self] fraction in
                Task { @MainActor in job?.fraction = fraction }
            }
            let copy = try await FFmpeg.makePlayableCopy(of: url, progress: report)
            do {
                var video = try await MediaLoader.load(asset: AVURLAsset(url: copy), url: url)
                video.proxies = [copy]
                return video
            } catch {
                try? FileManager.default.removeItem(at: copy)
                throw error
            }
        }
        loadTask = task
        do {
            return try await task.value
        } catch is CancellationError {
            return nil
        } catch {
            message = error.localizedDescription
            return nil
        }
    }

    private func discardProxies() {
        for video in [video].compactMap({ $0 }) + undoStack {
            for proxy in video.proxies { try? FileManager.default.removeItem(at: proxy) }
        }
    }

    private func install(_ loaded: LoadedVideo) {
        let item = AVPlayerItem(asset: loaded.asset)
        item.videoComposition = loaded.videoComposition
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidEnd() }
        }
        // The first video in a window puts the list of videos away; the person can bring it back.
        if video == nil { columns = fullScreen ? columns : .detailOnly }
        video = loaded
        segment = nil
        direction = .forward
        refreshLook()
        seek(toFrame: 0)
    }

    /// True when the picture's mirror and adjustments cannot go through the player's own filter pass,
    /// because appended clips of different sizes already use a custom composition. The view draws them instead.
    var lookInView: Bool { video?.videoComposition != nil }

    /// Gives the player item the composition that mirrors and adjusts the picture.
    private func refreshLook() {
        lookTask?.cancel()
        guard let video, let item = player.currentItem, video.videoComposition == nil else { return }
        guard mirrored || !adjustments.isNeutral else {
            item.videoComposition = nil
            return
        }
        let asset = video.asset
        let (mirrored, adjustments) = (mirrored, adjustments)
        lookTask = Task {
            guard let composition = try? await PictureAdjuster.composition(for: asset, adjustments: adjustments, mirrored: mirrored),
                  !Task.isCancelled, player.currentItem === item else { return }
            item.videoComposition = composition
        }
    }

    /// Unloads the video and shows the empty window again.
    func close() {
        pause()
        discardProxies()
        undoStack = []
        player.replaceCurrentItem(with: nil)
        video = nil
        segment = nil
        currentFrame = 0
        if !fullScreen { columns = .all }
    }

    /// Snapshot mode shows the export sheet without running an export.
    func showSampleJob() { job = Job(title: "Exporting video…", fraction: 0.42) }
    func clearJob() { job = nil }

    // MARK: Transport

    func togglePlay() {
        isPlaying ? pause() : play()
    }

    func play() {
        guard let video else { return }
        let time = player.currentTime().seconds
        if let region = loopRegion, loopEnabled {
            if time < region.start - region.epsilon || time >= region.end - region.epsilon {
                seek(toFrame: Timeline.frameAtTime(video.frames, time: region.start))
            }
        } else if time >= video.duration - 0.02 {
            seek(toFrame: 0)
        }
        isPlaying = true
        direction = .forward
        applyRate()
    }

    func pause() {
        reverseTask?.cancel()
        reverseTask = nil
        guard isPlaying || player.rate != 0 else { return }
        isPlaying = false
        player.pause()
        if let video { currentFrame = Timeline.frameAtTime(video.frames, time: player.currentTime().seconds) }
    }

    func step(by count: Int) {
        pause()
        seek(toFrame: currentFrame + count)
    }

    func skip(seconds: Double) {
        guard let video else { return }
        let wasPlaying = isPlaying
        pause()
        seek(toFrame: Timeline.frameAtTime(video.frames, time: player.currentTime().seconds + seconds))
        if wasPlaying { play() }
    }

    func seek(toFrame frame: Int) {
        guard let video, !video.frames.isEmpty else { return }
        let index = Timeline.clampFrame(frame, frameCount: video.frames.count)
        currentFrame = index
        seekPlayer(to: video.frames[index].seekTime)
    }

    private func seekPlayer(to seconds: Double, completion: (@Sendable () -> Void)? = nil) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 90_000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            completion?()
        }
    }

    func beginScrub() {
        if scrubbingWasPlaying == nil {
            scrubbingWasPlaying = isPlaying
            pause()
        }
    }

    func scrub(toTime seconds: Double) {
        guard let video else { return }
        beginScrub()
        seek(toFrame: Timeline.frameAtTime(video.frames, time: seconds))
    }

    func endScrub() {
        let resume = scrubbingWasPlaying ?? false
        scrubbingWasPlaying = nil
        if resume { play() }
    }

    private func applyRate() {
        reverseTask?.cancel()
        reverseTask = nil
        if direction == .forward {
            player.rate = Float(speed)
        } else if player.currentItem?.canPlayReverse == true {
            player.rate = -Float(speed)
        } else {
            player.pause()
            reverseTask = Task { await stepBackward() }
        }
    }

    /// For files that cannot play in reverse: show earlier frames one by one.
    private func stepBackward() async {
        while !Task.isCancelled, isPlaying, direction == .backward, let video {
            seek(toFrame: currentFrame - 1)
            let frame = video.frames[currentFrame]
            if let region = loopRegion, case .jump(let time, let next) = region.action(time: frame.pts, direction: .backward) {
                perform(time: time, direction: next)
                return
            }
            if currentFrame == 0 { pause(); return }
            try? await Task.sleep(for: .seconds(frame.duration / speed))
        }
    }

    // MARK: Looping

    var loopRegion: LoopRegion? {
        guard let video, !video.frames.isEmpty else { return nil }
        let frames = video.frames
        if let marked = segment, let endFrame = marked.endFrame {
            let start = Timeline.clampFrame(marked.startFrame, frameCount: frames.count)
            let end = Timeline.clampFrame(endFrame, frameCount: frames.count)
            if start <= end {
                return LoopRegion(start: frames[start].pts, end: frames[end].end, clipDuration: video.duration, pingPong: pingPong)
            }
            // A ping-pong loop has no way round the end of the clip: play the span between the marks instead.
            return pingPong
                ? LoopRegion(start: frames[end].pts, end: frames[start].end, clipDuration: video.duration, pingPong: true)
                : LoopRegion(start: frames[start].pts, end: frames[end].end, clipDuration: video.duration, wraps: true)
        }
        return LoopRegion(start: frames[0].pts, end: video.duration, clipDuration: video.duration, pingPong: pingPong)
    }

    private func tick(_ time: Double) {
        guard let video, !jumping, time.isFinite else { return }
        guard isPlaying else { return }
        currentFrame = Timeline.frameAtTime(video.frames, time: time)
        guard loopEnabled, let region = loopRegion, direction == .forward || player.currentItem?.canPlayReverse == true else { return }
        if case .jump(let target, let next) = region.action(time: time, direction: direction) {
            perform(time: target, direction: next)
        }
    }

    private func perform(time: Double, direction next: PlayDirection) {
        direction = next
        if next == .backward {
            applyRate()
            return
        }
        jumping = true
        seekPlayer(to: time) { [weak self] in
            Task { @MainActor in
                self?.jumping = false
                if self?.isPlaying == true { self?.applyRate() }
            }
        }
    }

    private func itemDidEnd() {
        guard isPlaying, let video else { return }
        if loopEnabled {
            tick(video.duration)
        } else {
            isPlaying = false
            currentFrame = video.frames.count - 1
        }
    }

    // MARK: Segment

    func markStart() {
        segment = Segment(startFrame: currentFrame, endFrame: segment?.endFrame)
    }

    func markEnd() {
        segment = Segment(startFrame: segment?.startFrame ?? 0, endFrame: currentFrame)
    }

    func setSegmentStart(frame: Int) {
        segment = Segment(startFrame: frame, endFrame: segment?.endFrame)
    }

    func setSegmentEnd(frame: Int) {
        segment = Segment(startFrame: segment?.startFrame ?? 0, endFrame: frame)
    }

    func resetSegment() {
        segment = nil
    }

    // MARK: Editing

    var canUndo: Bool { !undoStack.isEmpty && job == nil && !isLoading }
    var canDelete: Bool { video != nil && segment?.isComplete == true && job == nil && !isLoading }
    var canAppend: Bool { video != nil && job == nil && !isLoading }

    /// Cuts the marked segment out of the clip. The file on disk is not touched.
    func deleteSelection() async {
        guard canDelete, let video, let segment else { return }
        pause()
        let frames = video.frames
        var edits = video.edits
        // Cut at the middle between two frames, so rounding never keeps or drops a neighbour.
        func boundary(before frame: Int) -> Double { frame == 0 ? 0 : (frames[frame - 1].pts + frames[frame].pts) / 2 }
        func boundary(after frame: Int) -> Double { frame == frames.count - 1 ? video.duration : (frames[frame].pts + frames[frame + 1].pts) / 2 }
        // Latest first, so an earlier cut does not shift the time of a later one.
        for range in Timeline.segmentRanges(segment, frameCount: frames.count).sorted(by: { $0.lowerBound > $1.lowerBound }) {
            edits.remove(from: boundary(before: range.lowerBound), to: boundary(after: range.upperBound))
        }
        guard !edits.pieces.isEmpty else {
            message = "That would delete the whole clip."
            return
        }
        let resumeFrame = Timeline.segmentRanges(segment, frameCount: frames.count).map(\.lowerBound).min() ?? 0
        await applyEdit(edits: edits, sources: video.sources, resumeFrame: resumeFrame)
    }

    /// Adds another video to the end of the clip.
    func append(_ url: URL) async {
        guard canAppend, let video else { return }
        pause()
        guard FileManager.default.fileExists(atPath: url.path) else {
            message = "\(url.lastPathComponent) no longer exists."
            return
        }
        guard let other = await loadVideo(url), let source = other.sources.first else { return }
        var sources = video.sources
        sources.append(source)
        var edits = video.edits
        edits.append(EditPiece(source: sources.count - 1, start: 0, end: source.duration))
        await applyEdit(edits: edits, sources: sources, resumeFrame: video.frames.count, extraProxies: other.proxies)
    }

    func undoEdit() {
        guard canUndo, let previous = undoStack.popLast() else { return }
        pause()
        let frame = currentFrame
        install(previous)
        seek(toFrame: frame)
    }

    private func applyEdit(edits: EditList, sources: [EditSource], resumeFrame: Int, extraProxies: [URL] = []) async {
        guard let current = video else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let built = try await EditBuilder.build(sources: sources, edits: edits)
            var edited = current
            edited.asset = built.asset
            edited.sources = sources
            edited.edits = edits
            edited.videoComposition = built.videoComposition
            edited.proxies = current.proxies + extraProxies
            edited.frames = edits.frames(sourceFrames: sources.map(\.frames))
            edited.duration = edits.duration
            if edited.frames.count > 1, let last = edited.frames.last {
                edited.frameRate = Double(edited.frames.count - 1) / (last.pts - edited.frames[0].pts)
            }
            undoStack.append(current)
            install(edited)
            seek(toFrame: resumeFrame)
        } catch {
            message = error.localizedDescription
        }
    }

    // MARK: Saving

    var canExport: Bool { video != nil && job == nil }

    func saveScreenshot() {
        guard let video, job == nil else { return }
        let frame = currentFrame
        let mirrored = mirrored
        let adjustments = adjustments
        Task {
            do {
                let url = try AppSettings.shared.allocate(.screenshot)
                try await Exporter.screenshot(video: video, frame: frame, mirrored: mirrored, adjustments: adjustments, to: url)
                toast = Toast(text: "Saved \(url.lastPathComponent)", url: url)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    /// Frames the export covers, in play order: the marked segment (or the whole clip), with the ping-pong return if on.
    func exportOrder() -> [Int] {
        guard let video else { return [] }
        let ranges = segment?.isComplete == true
            ? Timeline.segmentRanges(segment!, frameCount: video.frames.count)
            : [0...(video.frames.count - 1)]
        let forward = ranges.flatMap { Array($0) }
        return pingPong ? Timeline.pingPongOrder(forward) : forward
    }

    func export(_ format: ExportFormat) {
        guard let video, job == nil else { return }
        if let problem = format.problem(for: video) {
            message = problem
            return
        }
        pause()
        let order = exportOrder()
        let speed = speed
        let mirrored = mirrored
        let adjustments = adjustments
        job = Job(title: format.jobTitle, fraction: 0)
        exportTask = Task {
            defer {
                job = nil
                exportTask = nil
            }
            var output: URL?
            do {
                let url = try AppSettings.shared.allocate(format == .gif ? .gif : .mp4)
                output = url
                let report: @Sendable (Double) -> Void = { [self] fraction in
                    Task { @MainActor in job?.fraction = fraction }
                }
                let retitle: @Sendable (String) -> Void = { [self] title in
                    Task { @MainActor in job?.title = title }
                }
                switch format {
                case .mp4Original:
                    try await Exporter.exportMP4(video: video, order: order, speed: speed, mirrored: mirrored, adjustments: adjustments,
                                                 target: .original(of: video), to: url, progress: report)
                case .mp4Small:
                    try await Exporter.exportMP4(video: video, order: order, speed: speed, mirrored: mirrored, adjustments: adjustments,
                                                 target: .small, to: url, progress: report)
                case .mp4Upscaled, .mp4UpscaledFast:
                    try await Exporter.exportMP4(video: video, order: order, speed: speed, mirrored: mirrored, adjustments: adjustments,
                                                 target: .upscaled(of: video), upscale: format.upscaleQuality, to: url,
                                                 phase: retitle, progress: report)
                case .gif:
                    try await Exporter.exportGIF(video: video, order: order, speed: speed, mirrored: mirrored, adjustments: adjustments, to: url, progress: report)
                }
                toast = Toast(text: "Saved \(url.lastPathComponent)", url: url)
            } catch is CancellationError {
                if let output { try? FileManager.default.removeItem(at: output) }
            } catch {
                message = error.localizedDescription
            }
        }
    }

    func cancelJob() {
        exportTask?.cancel()
        loadTask?.cancel()
    }

    /// Awaits a running export. Used by the self-test.
    func waitForJob() async {
        await exportTask?.value
    }
}
