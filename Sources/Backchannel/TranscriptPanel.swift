import AppKit
import SwiftUI

/// Floating transcript that sits as a small icon and expands into the full transcript on hover.
@MainActor
final class TranscriptPanel: ObservableObject {
    @Published private(set) var expanded = false

    private var panel: NSPanel?
    private var timer: Timer?
    private var leftAt: Date?

    private let iconSize = NSSize(width: 44, height: 44)
    private let expandedSize = NSSize(width: 420, height: 560)
    /// How long the pointer must be gone before collapsing, so brief exits don't flicker.
    private let collapseDelay: TimeInterval = 0.5
    private let anchorKey = "transcriptIconAnchor"

    func show<Content: View>(_ content: Content) {
        if panel == nil { panel = makePanel(content) }
        collapse(animated: false)
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func hide() {
        timer?.invalidate()
        panel?.orderOut(nil)
    }

    private func makePanel<Content: View>(_ content: Content) -> NSPanel {
        let p = KeyablePanel(contentRect: NSRect(origin: .zero, size: iconSize),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.isReleasedWhenClosed = false
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.contentView = NSHostingView(rootView: content.environmentObject(self))
        NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification, object: p, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.saveAnchor() }
        }
        return p
    }

    private func tick() {
        guard let p = panel, p.isVisible else { return }
        let inside = p.frame.contains(NSEvent.mouseLocation)
        let dragging = NSEvent.pressedMouseButtons != 0
        if inside {
            leftAt = nil
            if !expanded && !dragging { expand() }
        } else if expanded && !dragging {
            if let leftAt, Date().timeIntervalSince(leftAt) > collapseDelay { collapse(animated: true) }
            else if leftAt == nil { leftAt = Date() }
        }
    }

    /// The icon's bottom-right corner; the expanded transcript grows up and left from it.
    private var anchor: NSPoint {
        if let s = UserDefaults.standard.string(forKey: anchorKey) {
            let p = NSPointFromString(s)
            if NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: p.x - 1, y: p.y + 1)) }) { return p }
        }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        return NSPoint(x: screen.maxX - 20, y: screen.minY + 20)
    }

    private func saveAnchor() {
        guard !expanded, let f = panel?.frame else { return }
        UserDefaults.standard.set(NSStringFromPoint(NSPoint(x: f.maxX, y: f.minY)), forKey: anchorKey)
    }

    private func expand() {
        guard let p = panel else { return }
        expanded = true
        let a = anchor
        var frame = NSRect(x: a.x - expandedSize.width, y: a.y, width: expandedSize.width, height: expandedSize.height)
        if let screen = (p.screen ?? NSScreen.main)?.visibleFrame {
            frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, screen.minY), screen.maxY - frame.height)
        }
        p.setFrame(frame, display: true, animate: true)
    }

    private func collapse(animated: Bool) {
        guard let p = panel else { return }
        expanded = false
        leftAt = nil
        let a = anchor
        let frame = NSRect(x: a.x - iconSize.width, y: a.y, width: iconSize.width, height: iconSize.height)
        p.setFrame(frame, display: true, animate: animated)
    }
}

/// Borderless panels can't become key by default, which blocks text selection and scrolling focus.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Root view: a solid icon when collapsed, the full transcript when expanded.
struct TranscriptBubble<Expanded: View>: View {
    @EnvironmentObject var panel: TranscriptPanel
    @EnvironmentObject var stream: TranscriptStream
    let content: Expanded

    var body: some View {
        if panel.expanded {
            content
                .background(Color(nsColor: .windowBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
        } else {
            ZStack(alignment: .topTrailing) {
                Circle()
                    .fill(Color(white: 0.15))
                    .overlay(Image(systemName: "captions.bubble.fill").font(.system(size: 18)).foregroundStyle(.white))
                Circle()
                    .fill(stream.talkingToAgent ? .purple : stream.status == "Live" ? .green : .orange)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().strokeBorder(Color(white: 0.15), lineWidth: 2))
            }
            .frame(width: 44, height: 44)
        }
    }
}
