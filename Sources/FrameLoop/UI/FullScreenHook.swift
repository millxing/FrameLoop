import AppKit
import SwiftUI

extension View {
    /// Gives `model` its window and keeps `model.fullScreen` in step with the window, however it
    /// enters or leaves full screen (the button, the menu, the green button, Control-Command-F, Escape).
    func tracksFullScreen(_ model: PlayerModel) -> some View {
        background(FullScreenHook(model: model))
    }
}

private struct FullScreenHook: NSViewRepresentable {
    let model: PlayerModel

    func makeNSView(context: Context) -> Probe {
        Probe(model: model)
    }

    func updateNSView(_ probe: Probe, context: Context) {}

    final class Probe: NSView {
        private let model: PlayerModel

        init(model: PlayerModel) {
            self.model = model
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { fatalError("not used") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            NotificationCenter.default.removeObserver(self)
            guard let window else { return }
            model.window = window
            model.fullScreen = window.styleMask.contains(.fullScreen)
            // "Will" notifications, so the sidebar and toolbar are already gone while the window animates.
            NotificationCenter.default.addObserver(self, selector: #selector(entering), name: NSWindow.willEnterFullScreenNotification, object: window)
            NotificationCenter.default.addObserver(self, selector: #selector(leaving), name: NSWindow.willExitFullScreenNotification, object: window)
        }

        @objc private func entering() { model.fullScreen = true }
        @objc private func leaving() { model.fullScreen = false }
    }
}
