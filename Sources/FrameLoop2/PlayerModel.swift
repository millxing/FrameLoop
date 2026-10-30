@preconcurrency import AVFoundation
import AppKit
import FrameLoop2Kit
import Observation

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
    var mirrored = false
    var segment: Segment?
    var loopEnabled = false
    var pingPong = false
    var message: String?
    var toast: Toast?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var jumping = false
    @ObservationIgnored private var scrubbingWasPlaying: Bool?
    @ObservationIgnored private var reverseTask: Task<Void, Never>?
    @ObservationIgnored private var exportTask: Task<Void, Never>?

    init() {
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 120), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
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
        isLoading = true
        defer { isLoading = false }
        do {
            install(try await MediaLoader.load(url: url))
        } catch {
            message = error.localizedDescription
        }
    }

    private func install(_ loaded: LoadedVideo) {
        let item = AVPlayerItem(asset: loaded.asset)
        item.audioTimePitchAlgorithm = .spectral
        player.replaceCurrentItem(with: item)
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.itemDidEnd() }
        }
        video = loaded
        segment = nil
        direction = .forward
        seek(toFrame: 0)
    }

    /// Unloads the video and shows the empty window again.
    func close() {
        pause()
        player.replaceCurrentItem(with: nil)
        video = nil
        segment = nil
        currentFrame = 0
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

    // MARK: Saving

    var canExport: Bool { video != nil && job == nil }

    func saveScreenshot() {
        guard let video, job == nil else { return }
        let frame = currentFrame
        let mirrored = mirrored
        Task {
            do {
                let url = try AppSettings.shared.allocate(.screenshot)
                try await Exporter.screenshot(video: video, frame: frame, mirrored: mirrored, to: url)
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
        pause()
        let order = exportOrder()
        let speed = speed
        let mirrored = mirrored
        job = Job(title: format == .mp4 ? "Exporting video…" : "Exporting GIF…", fraction: 0)
        exportTask = Task {
            defer {
                job = nil
                exportTask = nil
            }
            var output: URL?
            do {
                let url = try AppSettings.shared.allocate(format == .mp4 ? .mp4 : .gif)
                output = url
                let report: @Sendable (Double) -> Void = { [self] fraction in
                    Task { @MainActor in job?.fraction = fraction }
                }
                switch format {
                case .mp4: try await Exporter.exportMP4(video: video, order: order, speed: speed, mirrored: mirrored, to: url, progress: report)
                case .gif: try await Exporter.exportGIF(video: video, order: order, speed: speed, mirrored: mirrored, to: url, progress: report)
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
    }

    /// Awaits a running export. Used by the self-test.
    func waitForJob() async {
        await exportTask?.value
    }
}
