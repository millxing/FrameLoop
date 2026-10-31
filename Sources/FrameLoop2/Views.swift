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
        NavigationSplitView(columnVisibility: $model.columns) {
            SidebarView(model: model, library: library)
                .navigationSplitViewColumnWidth(min: 200, ideal: 240, max: 360)
        } detail: {
            PlayerScreen(model: model)
        }
        .navigationTitle(model.video?.url.lastPathComponent ?? "FrameLoop2")
        .toolbar { PlayerToolbar(model: model) }
        .focusedSceneValue(\.player, model)
        .tracksFullScreen(model)
        .noInitialFocus()
        .frame(minHeight: 520)
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
            .tip("Open a video (Command-O)")
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
            .tip("Playback and export speed (Control-1 to 7)")
            Toggle(isOn: $model.loopEnabled) { Label("Loop", systemImage: "repeat") }
                .tip("Loop the segment (L)")
            Toggle(isOn: $model.pingPong) { Label("Reverse Loop", systemImage: "arrow.left.arrow.right") }
                .tip("Play the loop forward, then backward (R)")
            Toggle(isOn: $model.mirrored) { Label("Mirror", systemImage: "arrow.trianglehead.left.and.right.righttriangle.left.righttriangle.right") }
                .tip("Flip the picture left to right (M)")
        }
        ToolbarItemGroup {
            Toggle(isOn: $model.showInfo) { Label("Video Info", systemImage: "info.circle") }
                .tip("Show the picture size and frame rate (Option-Command-I)")
            Toggle(isOn: $model.showAdjustments) { Label("Adjustments", systemImage: "slider.horizontal.3") }
                .tip("Brightness, contrast, saturation, and more (Option-Command-A)")
            Button("Full Screen", systemImage: "arrow.up.left.and.arrow.down.right") { model.toggleFullScreen() }
                .disabled(!model.canFullScreen)
                .tip("Play the video full screen (F). Escape leaves full screen.")
        }
        ToolbarItemGroup {
            Button("Delete Selection", systemImage: "trash") { Task { await model.deleteSelection() } }
                .disabled(!model.canDelete)
                .tip("Cut the segment out of the clip (Delete)")
            Button("Append Video", systemImage: "plus.rectangle.on.rectangle") {
                if let url = Panels.chooseVideo() { Task { await model.append(url) } }
            }
            .disabled(!model.canAppend)
            .tip("Add a video to the end (Shift-Command-O)")
            Button("Undo", systemImage: "arrow.uturn.backward") { model.undoEdit() }
                .disabled(!model.canUndo)
                .tip("Undo last append or delete (Command-Z)")
        }
        ToolbarItemGroup {
            Button("Screenshot", systemImage: "camera") { model.saveScreenshot() }
                .disabled(!model.canExport)
                .tip("Save the current frame as a PNG (S)")
            Menu {
                ForEach(ExportFormat.allCases, id: \.self) { format in
                    Button(format.title) { model.export(format) }
                        .disabled(model.video.flatMap(format.problem(for:)) != nil)
                }
            } label: {
                Label("Export Segment", systemImage: "square.and.arrow.up")
            } primaryAction: {
                model.export(.mp4Original)
            }
            .disabled(!model.canExport)
            .tip("Export the segment as an MP4 at the original size (Command-E). Use the arrow for other formats.")
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
                .tip("Choose which folder to list")
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await library.refresh() } }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .tip("Refresh the list")
            }
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.sm)
        }
    }
}

// MARK: Player

struct PlayerScreen: View {
    @Bindable var model: PlayerModel
    /// In full screen the controls show while the pointer moves and fade away after a rest.
    @State private var controlsShown = true
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if model.video != nil {
                Color.black
                PlayerSurface(player: model.player,
                              mirrored: model.lookInView && model.mirrored,
                              adjustments: model.lookInView ? model.adjustments : Adjustments())
                    .contentShape(Rectangle())
                    .onTapGesture { model.togglePlay() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
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
        .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.video != nil, !model.fullScreen { Controls(model: model) }
        }
        .overlay(alignment: .bottom) {
            if model.video != nil, model.fullScreen {
                Controls(model: model)
                    .frame(maxWidth: 900)
                    .opacity(controlsShown ? 1 : 0)
                    .allowsHitTesting(controlsShown)
                    .animation(.easeInOut(duration: 0.25), value: controlsShown)
            }
        }
        .onContinuousHover { phase in
            if case .active = phase, model.fullScreen { revealControls() }
        }
        .onChange(of: model.fullScreen) { _, on in
            if on { revealControls() } else { hideTask?.cancel() }
        }
        .overlay(alignment: .topLeading) {
            if model.showInfo, let video = model.video { VideoInfoBadge(video: video) }
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
        .inspector(isPresented: $model.showAdjustments) {
            AdjustmentsPanel(model: model)
                .inspectorColumnWidth(min: 240, ideal: 260, max: 320)
        }
    }
}

extension PlayerScreen {
    private func revealControls() {
        controlsShown = true
        hideTask?.cancel()
        hideTask = Task {
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled, model.fullScreen else { return }
            controlsShown = false
            NSCursor.setHiddenUntilMouseMoves(true)
        }
    }
}

/// Picture size and frame rate, over the corner of the video.
struct VideoInfoBadge: View {
    let video: LoadedVideo

    var body: some View {
        Text(video.summary)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.white) // text over user content sits on a dark scrim
            .padding(.horizontal, Space.md)
            .padding(.vertical, Space.xs)
            .background(.black.opacity(0.6), in: .capsule)
            .padding(Space.md)
            .allowsHitTesting(false)
            .accessibilityLabel("Video info: \(video.summary)")
    }
}

/// Brightness, contrast, saturation, exposure, and hue. They change the picture you see, screenshots, and exports.
struct AdjustmentsPanel: View {
    @Bindable var model: PlayerModel

    var body: some View {
        Form {
            Section {
                row("Brightness", value: $model.adjustments.brightness, range: -1...1, neutral: 0, format: "%+.2f")
                row("Contrast", value: $model.adjustments.contrast, range: 0...2, neutral: 1, format: "%.2f")
                row("Saturation", value: $model.adjustments.saturation, range: 0...2, neutral: 1, format: "%.2f")
                row("Exposure", value: $model.adjustments.exposure, range: -2...2, neutral: 0, format: "%+.1f EV")
                row("Hue", value: $model.adjustments.hue, range: -180...180, neutral: 0, format: "%+.0f°")
            } footer: {
                Text("Applies to the picture, screenshots, and exports. The file is not changed. Double-click a slider's name to reset it.")
            }
            Section {
                Button("Reset All") { model.adjustments = Adjustments() }
                    .disabled(model.adjustments.isNeutral)
                    .tip("Put every control back to its neutral setting")
            }
        }
        .formStyle(.grouped)
        .noInitialFocus()
    }

    private func row(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, neutral: Double, format: String) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack {
                Text(title)
                    .onTapGesture(count: 2) { value.wrappedValue = neutral }
                Spacer()
                Text(String(format: format, value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .tip("\(title). Double-click its name to reset.")
        }
    }
}

struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer
    let mirrored: Bool
    let adjustments: Adjustments

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.mirrored = mirrored
        view.setFilters(PictureAdjuster.filters(adjustments))
    }

    /// Only used when the player's composition is taken (appended clips of different sizes): the picture sits in its
    /// own layer, and mirroring flips that layer around its vertical centre line.
    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        var mirrored = false { didSet { if mirrored != oldValue { needsLayout = true } } }

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layerUsesCoreImageFilters = true
            layer?.backgroundColor = NSColor.black.cgColor
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
        }

        required init?(coder: NSCoder) { fatalError() }

        func setFilters(_ filters: [CIFilter]) {
            playerLayer.filters = filters.isEmpty ? nil : filters
        }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.bounds = CGRect(origin: .zero, size: bounds.size)
            playerLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
            playerLayer.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
            CATransaction.commit()
        }
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
            // Wide: everything on one row. Narrow (an open side panel): the transport gets a row of its own.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Space.md) {
                    readout
                    Spacer(minLength: Space.md)
                    transport
                    Spacer(minLength: Space.md)
                    volume
                }
                VStack(spacing: Space.sm) {
                    HStack(spacing: Space.md) {
                        readout
                        Spacer(minLength: Space.md)
                        volume
                    }
                    transport
                }
            }
            // The wide row's width must not become the window's minimum, or a side panel pushes past the edge.
            .frame(minWidth: 0)
        }
        .padding(.horizontal, Space.lg)
        .padding(.vertical, Space.md)
        .glassEffect(.regular, in: .rect(cornerRadius: Space.lg))
        .padding(Space.md)
        .gridArea("controls", inset: Space.md)
    }

    private var volume: some View {
        HStack(spacing: Space.sm) {
            Image(systemName: model.volume == 0 ? "speaker.slash" : "speaker.wave.2").foregroundStyle(.secondary)
                .tip("Volume")
            Slider(value: $model.volume, in: 0...1).frame(width: 96)
                .accessibilityLabel("Volume")
                .tip("Volume")
        }
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
                .tip("Back 10 seconds (Shift-Left Arrow)")
            Button("Previous frame", systemImage: "backward.frame") { model.step(by: -1) }
                .tip("Previous frame (Left Arrow)")
            Button(model.isPlaying ? "Pause" : "Play", systemImage: model.isPlaying ? "pause.fill" : "play.fill") { model.togglePlay() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tip(model.isPlaying ? "Pause (Space)" : "Play (Space)")
            Button("Next frame", systemImage: "forward.frame") { model.step(by: 1) }
                .tip("Next frame (Right Arrow)")
            Button("Forward 10 seconds", systemImage: "goforward.10") { model.skip(seconds: 10) }
                .tip("Forward 10 seconds (Shift-Right Arrow)")
            Divider().frame(height: Space.lg)
            Button("Segment start", systemImage: "arrow.down.to.line.compact") { model.markStart() }
                .tip("Mark the segment start (I)")
            Button("Segment end", systemImage: "arrow.up.to.line.compact") { model.markEnd() }
                .tip("Mark the segment end (O)")
            Button("Reset selection", systemImage: "xmark.circle") { model.resetSegment() }
                .disabled(model.segment == nil)
                .tip("Clear the segment")
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
            .tip("\(label): drag to move it")
            .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .named("timeline"))
                .onChanged { drag in
                    let fraction = min(max(drag.location.x / max(1, width), 0), 1)
                    move(Double(fraction) * duration)
                })
    }
}
