@preconcurrency import AVFoundation
import AppKit
import FrameLoop2Kit
import SwiftUI
import UniformTypeIdentifiers

// MARK: Window

/// Identifies a player window. A fresh `id` makes a new window; `url` is the video it opens with.
struct WindowRequest: Codable, Hashable {
    var id = UUID()
    var url: URL?
}

/// Files that Finder, the Dock, or `open` sent while no window could take them.
@Observable
final class OpenRouter {
    static let shared = OpenRouter()
    var pending: [URL] = []

    func take() -> URL? {
        pending.isEmpty ? nil : pending.removeFirst()
    }
}

struct PlayerKey: FocusedValueKey {
    typealias Value = PlayerModel
}

extension FocusedValues {
    var player: PlayerModel? {
        get { self[PlayerKey.self] }
        set { self[PlayerKey.self] = newValue }
    }
}

enum Panels {
    @MainActor
    static func chooseVideo() -> URL? {
        let panel = NSOpenPanel()
        panel.title = "Open Video"
        panel.allowedContentTypes = MediaFormats.supported.compactMap { UTType(filenameExtension: $0) }
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    @MainActor
    static func chooseFolder(title: String, current: String) -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: current)
        return panel.runModal() == .OK ? panel.url : nil
    }
}

struct PlayerWindow: View {
    let request: WindowRequest?
    @State private var model = PlayerModel()
    @State private var library = Library()
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings
    private let router = OpenRouter.shared

    var body: some View {
        NavigationSplitView {
            SidebarView(model: model, library: library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            PlayerScreen(model: model)
        }
        .navigationTitle(model.video?.url.lastPathComponent ?? "FrameLoop2")
        .navigationSubtitle(model.video?.summary ?? "")
        .toolbar { PlayerToolbar(model: model) }
        .focusedSceneValue(\.player, model)
        .noInitialFocus()
        .frame(minWidth: 840, minHeight: 520)
        .task {
            if let url = request?.url { await model.open(url) }
            await library.refresh()
            await consumePending()
            SelfTest.runIfRequested(model: model, library: library)
            Snapshot.runIfRequested(model: model, library: library, openSettings: openSettings)
        }
        .onChange(of: router.pending) {
            Task { await consumePending() }
        }
        .onChange(of: library.folderID) {
            Task { await library.refresh() }
        }
    }

    /// A blank window takes the file itself. Any other window opens it in a new one.
    private func consumePending() async {
        while let url = router.take() {
            if model.video == nil {
                await model.open(url)
            } else {
                openWindow(value: WindowRequest(url: url))
            }
        }
    }
}

// MARK: Toolbar

struct PlayerToolbar: ToolbarContent {
    @Bindable var model: PlayerModel

    var body: some ToolbarContent {
        ToolbarItemGroup {
            Button("Open Video", systemImage: "folder") {
                if let url = Panels.chooseVideo() { Task { await model.open(url) } }
            }
            .help("Open a video (Command-O)")
        }
        ToolbarItemGroup {
            Menu {
                Picker("Speed", selection: $model.speed) {
                    ForEach(PlaybackSpeed.all, id: \.self) { Text(PlaybackSpeed.label($0)).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(PlaybackSpeed.label(model.speed), systemImage: "speedometer")
            }
            .help("Loop playback and export speed")
            Toggle(isOn: $model.loopEnabled) { Label("Loop", systemImage: "repeat") }
                .help("Loop the segment (L)")
            Toggle(isOn: $model.pingPong) { Label("Reverse Loop", systemImage: "arrow.left.arrow.right") }
                .help("Play the loop forward, then backward (R)")
            Toggle(isOn: $model.mirrored) { Label("Mirror", systemImage: "arrow.trianglehead.left.and.right.righttriangle.left.righttriangle.right") }
                .help("Flip the picture (M)")
        }
        ToolbarItemGroup {
            Button("Screenshot", systemImage: "camera") { model.saveScreenshot() }
                .disabled(!model.canExport)
                .help("Save the current frame as a PNG (S)")
            Menu {
                Button(ExportFormat.mp4.title) { model.export(.mp4) }
                Button(ExportFormat.gif.title) { model.export(.gif) }
            } label: {
                Label("Export Segment", systemImage: "square.and.arrow.up")
            }
            .disabled(!model.canExport)
            .help("Export the segment")
        }
    }
}

// MARK: Sidebar

struct SidebarView: View {
    let model: PlayerModel
    @Bindable var library: Library
    private let settings = AppSettings.shared

    var body: some View {
        List(library.files, id: \.self, selection: Binding(
            get: { model.video?.url },
            set: { url in if let url { Task { await model.open(url) } } })
        ) { url in
            Label(url.lastPathComponent, systemImage: "film")
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .overlay {
            if library.files.isEmpty {
                ContentUnavailableView("No supported videos", systemImage: "film.stack",
                                       description: Text(library.isMissing ? "This folder was not found." : "MP4 · M4V · MOV · MKV · AVI · FLV · GIF"))
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack(spacing: Space.sm) {
                Picker("Folder", selection: $library.folderID) {
                    ForEach(settings.folderSlots) { Text($0.label).tag($0.id) }
                }
                .labelsHidden()
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Refresh the list")
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }
}

// MARK: Player

struct PlayerScreen: View {
    @Bindable var model: PlayerModel

    var body: some View {
        ZStack {
            if model.video != nil {
                Color.black
                PlayerSurface(player: model.player, mirrored: model.mirrored)
            } else if model.isLoading {
                ProgressView("Preparing media…")
            } else {
                ContentUnavailableView {
                    Label("Open or drop a video", systemImage: "film")
                } description: {
                    Text("MP4 · M4V · MOV · MKV · AVI · FLV · GIF")
                } actions: {
                    Button("Open Video…") {
                        if let url = Panels.chooseVideo() { Task { await model.open(url) } }
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.video != nil { Controls(model: model) }
        }
        .overlay(alignment: .top) {
            if let message = model.message { Banner(text: message) { model.message = nil } }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast) { model.toast = nil }
                    .padding(.bottom, Space.section * 4)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: MediaFormats.isSupported) else {
                model.message = "That file is not a supported video."
                return false
            }
            Task { await model.open(url) }
            return true
        }
        .sheet(isPresented: Binding(get: { model.job != nil }, set: { _ in })) {
            JobSheet(model: model)
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let mirrored: Bool

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.playerLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer = playerLayer
        }

        required init?(coder: NSCoder) { fatalError() }
    }
}

struct Banner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            Text(text).lineLimit(3)
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: Space.lg))
        .padding(Space.lg)
    }
}

struct ToastView: View {
    let toast: PlayerModel.Toast
    let dismiss: () -> Void

    var body: some View {
        HStack(spacing: Space.md) {
            Label(toast.text, systemImage: "checkmark.circle.fill")
            if let url = toast.url {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .capsule)
        .task(id: toast.id) {
            try? await Task.sleep(for: .seconds(4))
            dismiss()
        }
    }
}

struct JobSheet: View {
    let model: PlayerModel

    var body: some View {
        VStack(alignment: .leading, spacing: Space.lg) {
            Text(model.job?.title ?? "").font(.headline)
            ProgressView(value: model.job?.fraction ?? 0)
            HStack {
                Text("\(Int((model.job?.fraction ?? 0) * 100)) %").monospacedDigit().foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelJob() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(Space.xxl)
        .frame(width: 360)
        .noInitialFocus()
    }
}

// MARK: Controls

struct Controls: View {
    @Bindable var model: PlayerModel

    var body: some View {
        VStack(spacing: Space.sm) {
            TimelineBar(model: model)
            HStack(spacing: Space.md) {
                readout
                Spacer(minLength: Space.md)
                transport
                Spacer(minLength: Space.md)
                HStack(spacing: Space.sm) {
                    Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                    Slider(value: $model.volume, in: 0...1).frame(width: 96)
                        .accessibilityLabel("Volume")
                }
            }
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: Space.lg))
        .padding(Space.md)
        .gridArea("controls", inset: Space.md)
    }

    private var readout: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(Timeline.formatTime(model.video.map { $0.frames[min(model.currentFrame, $0.frames.count - 1)].pts } ?? 0))
                .font(.system(.body, design: .monospaced))
            Text("Frame \(model.currentFrame + 1) of \(model.video?.frames.count ?? 0)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
        .frame(width: 148, alignment: .leading)
        .gridProbe("readout", area: "controls", edge: nil)
    }

    private var transport: some View {
        HStack(spacing: Space.sm) {
            Button("Back 10 seconds", systemImage: "gobackward.10") { model.skip(seconds: -10) }
            Button("Previous frame", systemImage: "backward.frame") { model.step(by: -1) }
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("Next frame", systemImage: "forward.frame") { model.step(by: 1) }
            Button("Forward 10 seconds", systemImage: "goforward.10") { model.skip(seconds: 10) }
            Divider().frame(height: Space.lg)
            Button("Segment start", systemImage: "arrow.down.to.line.compact") { model.markStart() }
                .help("Mark the segment start (I)")
            Button("Segment end", systemImage: "arrow.up.to.line.compact") { model.markEnd() }
                .help("Mark the segment end (O)")
            Button("Reset selection", systemImage: "xmark.circle") { model.resetSegment() }
                .disabled(model.segment == nil)
                .help("Clear the segment")
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
        .font(.title3)
    }
}

struct TimelineBar: View {
    let model: PlayerModel
    private let handleWidth: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let video = model.video
            let duration = max(video?.duration ?? 1, 0.001)
            let x: (Double) -> CGFloat = { CGFloat($0 / duration) * width }
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary).frame(height: 4)
                if let video, let segment = model.segment {
                    ForEach(Array(Timeline.segmentRanges(segment, frameCount: video.frames.count).enumerated()), id: \.offset) { _, range in
                        let from = x(video.frames[range.lowerBound].pts)
                        let to = x(video.frames[range.upperBound].end)
                        Capsule().fill(Palette.accent.opacity(0.5))
                            .frame(width: max(to - from, 2), height: 8)
                            .offset(x: from) // grid: ok position follows the video time
                    }
                    handle(at: x(video.frames[Timeline.clampFrame(segment.startFrame, frameCount: video.frames.count)].pts), label: "Segment start", width: width, duration: duration) { time in
                        model.setSegmentStart(frame: Timeline.frameAtTime(video.frames, time: time))
                    }
                    if let end = segment.endFrame {
                        handle(at: x(video.frames[Timeline.clampFrame(end, frameCount: video.frames.count)].end), label: "Segment end", width: width, duration: duration) { time in
                            model.setSegmentEnd(frame: Timeline.frameAtTime(video.frames, time: time))
                        }
                    }
                }
                if let video {
                    Capsule().fill(.primary)
                        .frame(width: 2, height: 20)
                        .offset(x: x(video.frames[min(model.currentFrame, video.frames.count - 1)].pts) - 1) // grid: ok position follows the video time
                        .accessibilityLabel("Video playhead")
                }
            }
            .frame(maxHeight: .infinity)
            .coordinateSpace(.named("timeline"))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { drag in model.scrub(toTime: Double(min(max(drag.location.x / width, 0), 1)) * duration) }
                .onEnded { _ in model.endScrub() })
        }
        .frame(height: 24)
    }

    private func handle(at position: CGFloat, label: String, width: CGFloat, duration: Double, move: @escaping (Double) -> Void) -> some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(Palette.accent)
            .frame(width: handleWidth, height: 20)
            .offset(x: position - handleWidth / 2) // grid: ok position follows the video time
            .accessibilityLabel(label)
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { drag in
                    let fraction = min(max(drag.location.x / max(1, width), 0), 1)
                    move(Double(fraction) * duration)
                })
    }
}
