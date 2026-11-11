import AppKit
import SwiftUI

extension View {
    /// A tooltip: after the pointer rests on the view for half a second, a small label shows below it.
    /// Drawn by the app instead of the system's `.help`, so it shows the same way in the toolbar, the controls bar, and the sidebar.
    func tip(_ text: String) -> some View {
        background(TipAnchor(text: text))
    }
}

private struct TipAnchor: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> TipView {
        TipView()
    }

    func updateNSView(_ view: TipView, context: Context) {
        view.text = text
    }
}

/// An invisible view behind a control that watches the pointer enter and leave.
final class TipView: NSView {
    var text = ""
    private var timer: Timer?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func mouseEntered(with event: NSEvent) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { if let self { TipPanel.shared.show(self.text, below: self) } }
        }
    }

    override func mouseExited(with event: NSEvent) {
        timer?.invalidate()
        TipPanel.shared.hide()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            timer?.invalidate()
            TipPanel.shared.hide()
        }
    }
}

/// The one tooltip label, a small borderless panel above the window.
@MainActor
final class TipPanel {
    static let shared = TipPanel()
    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private var monitor: Any?

    private init() {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.level = .floating
        let background = NSVisualEffectView()
        background.material = .menu
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 6
        background.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: background.topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -4),
        ])
        panel.contentView = background
    }

    var isShowing: Bool { panel.isVisible }
    var text: String { label.stringValue }

    func show(_ text: String, below view: NSView) {
        guard let window = view.window, !text.isEmpty else { return }
        label.stringValue = text
        panel.setContentSize(panel.contentView?.fittingSize ?? .zero)
        let anchor = window.convertToScreen(view.convert(view.bounds, to: nil))
        var origin = NSPoint(x: anchor.midX - panel.frame.width / 2, y: anchor.minY - panel.frame.height - 4)
        if let screen = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, screen.minX + 4), screen.maxX - panel.frame.width - 4)
            origin.y = max(origin.y, screen.minY + 4)
        }
        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        // A click, key press, or scroll dismisses it, like a system tooltip.
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) { [weak self] event in
                MainActor.assumeIsolated { self?.hide() }
                return event
            }
        }
    }

    func hide() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}
