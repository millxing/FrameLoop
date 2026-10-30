import AppKit
import FrameLoop2Kit
import SwiftUI

// FrameLoop2
//   FrameLoop2                      the app
//   APP_STORE=<file> FrameLoop2     test mode: settings and output stay in /tmp/FrameLoop2-scratch
//   APP_SNAPSHOT=<dir> FrameLoop2   save a PNG of every page and Settings tab in light and dark mode, then quit
//   FrameLoop2 --selftest           run the self-test and quit with 0 or 1 (tools/selftest.sh)
//   APP_ACCENT=<id> FrameLoop2      run with another accent from Theme.all (UI/Theme.swift)
//   APP_GRID=1 FrameLoop2           draw the grid and the layout probes over the window

@main
struct FrameLoop2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        WindowGroup("FrameLoop2", for: WindowRequest.self) { $request in
            PlayerWindow(request: request)
                .themed()
                .overlay { if GridOverlay.enabled { GridOverlay() } }
        } defaultValue: {
            WindowRequest()
        }
        .restorationBehavior(.disabled)
        .defaultSize(width: 1100, height: 720)
        .windowToolbarStyle(.unified)
        .commands { PlayerCommands() }

        Settings {
            SettingsView()
                .themed()
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Started from a terminal, the process is not a foreground app yet.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        FFmpeg.removeAllProxies()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        OpenRouter.shared.pending.append(contentsOf: urls.filter(MediaFormats.isSupported))
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The self-test's result becomes the exit code, after a normal quit.
    func applicationWillTerminate(_ notification: Notification) {
        FFmpeg.removeAllProxies()
        if SelfTest.requested { exit(SelfTest.exitCode) }
    }
}

struct PlayerCommands: Commands {
    @FocusedValue(\.player) private var player
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        SidebarCommands()
        ToolbarCommands()
        CommandGroup(replacing: .undoRedo) {
            Button("Undo Edit") { player?.undoEdit() }
                .keyboardShortcut("z")
                .disabled(!(player?.canUndo ?? false))
            Divider()
            Button("Delete Selection") { Task { await player?.deleteSelection() } }
                .keyboardShortcut(.delete, modifiers: [])
                .disabled(!(player?.canDelete ?? false))
            Button("Append Video…") {
                if let url = Panels.chooseVideo(), let player { Task { await player.append(url) } }
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(!(player?.canAppend ?? false))
        }
        CommandGroup(replacing: .newItem) {
            Button("New Window") { openWindow(value: WindowRequest()) }
                .keyboardShortcut("n")
            Button("Open Video…") {
                if let url = Panels.chooseVideo(), let player { Task { await player.open(url) } }
            }
            .keyboardShortcut("o")
            .disabled(player == nil)
            Divider()
            Button("Save Screenshot") { player?.saveScreenshot() }
                .keyboardShortcut("s", modifiers: [])
                .disabled(!(player?.canExport ?? false))
            Button("Export MP4…") { player?.export(.mp4) }
                .keyboardShortcut("e")
                .disabled(!(player?.canExport ?? false))
            Button("Export GIF…") { player?.export(.gif) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(!(player?.canExport ?? false))
        }
        CommandMenu("Playback") {
            Button(player?.isPlaying == true ? "Pause" : "Play") { player?.togglePlay() }
                .keyboardShortcut(.space, modifiers: [])
            Divider()
            Button("Previous Frame") { player?.step(by: -1) }
                .keyboardShortcut(.leftArrow, modifiers: [])
            Button("Next Frame") { player?.step(by: 1) }
                .keyboardShortcut(.rightArrow, modifiers: [])
            Button("Back 10 Seconds") { player?.skip(seconds: -10) }
                .keyboardShortcut(.leftArrow, modifiers: .shift)
            Button("Forward 10 Seconds") { player?.skip(seconds: 10) }
                .keyboardShortcut(.rightArrow, modifiers: .shift)
            Divider()
            Button("Set Segment Start") { player?.markStart() }
                .keyboardShortcut("i", modifiers: [])
            Button("Set Segment End") { player?.markEnd() }
                .keyboardShortcut("o", modifiers: [])
            Button("Reset Segment") { player?.resetSegment() }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(player?.segment == nil)
            Divider()
            Button(player?.loopEnabled == true ? "Stop Looping" : "Loop Segment") { player?.loopEnabled.toggle() }
                .keyboardShortcut("l", modifiers: [])
            Button(player?.pingPong == true ? "Turn Off Reverse Loop" : "Reverse Loop") { player?.pingPong.toggle() }
                .keyboardShortcut("r", modifiers: [])
            Button(player?.mirrored == true ? "Unmirror Picture" : "Mirror Picture") { player?.mirrored.toggle() }
                .keyboardShortcut("m", modifiers: [])
            Menu("Speed") {
                ForEach(Array(PlaybackSpeed.all.enumerated()), id: \.offset) { index, speed in
                    Button(PlaybackSpeed.label(speed)) { player?.speed = speed }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .control)
                }
            }
        }
    }
}
