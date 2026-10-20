import AppKit
import SwiftUI

/// An answer pushed by an agent: a title, an optional headline figure, optional label/value rows, and notes.
struct AgentCard: Identifiable, Codable, Equatable {
    var id = UUID()
    let title: String
    var headline: String?
    var caption: String?
    var rows: [[String]]?
    /// An optional horizontal bar chart for comparing a handful of numbers.
    var bars: CardBars?
    var detail: String?
    var source: String?
    /// SF Symbol name for the card's icon.
    var icon: String?
    /// Accent: violet (default), blue, green, orange, pink, red, teal.
    var tint: String?
    var shownAt = Date()
    /// The user's thumbs up (true) or down (false).
    var rating: Bool?
    /// An optional suggested action, shown as a button.
    var action: CardAction?
    /// Whether the action has already been clicked, so it can't fire twice.
    var actionTaken = false
    /// Cockpit-style alert level: "advisory", "caution" (default) or "warning". See `Level`.
    var priority: String?
    /// Whether an advisory card has been expanded to show its details.
    var expanded = false

    /// Like a cockpit's alerting: each level has its own spot on screen and its own insistence.
    enum Level {
        /// Be aware, look later: just the headline, muted, in the bottom-left corner.
        case advisory
        /// Look into it: the usual card, top right.
        case caution
        /// Act now: big and red at the top center, with a sound, until acknowledged.
        case warning
    }

    var level: Level {
        switch priority {
        case "advisory", "info": .advisory
        case "warning", "urgent": .warning
        default: .caution
        }
    }
    var warning: Bool { level == .warning }
    /// Warnings are always red.
    var accent: String? { warning ? "red" : tint }
    /// Advisories stay collapsed to their headline until expanded.
    var collapsed: Bool { level == .advisory && !expanded }

    private enum CodingKeys: String, CodingKey { case title, headline, caption, rows, bars, detail, source, icon, tint, action, priority }
}

/// A horizontal bar chart: `{"items": [["label", 1.6], ...], "unit": "%", "highlight": 2}`.
struct CardBars: Codable, Equatable {
    var items: [Bar]
    var unit: String?
    /// Index of the bar to emphasize; the others are muted. If absent, all bars are full strength.
    var highlight: Int?

    struct Bar: Codable, Equatable {
        let label: String
        let value: Double

        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            label = try c.decode(String.self)
            value = try c.decode(Double.self)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.unkeyedContainer()
            try c.encode(label)
            try c.encode(value)
        }
    }

    /// Formats a value without a trailing ".0", with thousands separators, plus the unit.
    func format(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = abs(value) >= 100 ? 0 : (abs(value) >= 10 ? 1 : 2)
        let n = f.string(from: NSNumber(value: value)) ?? String(value)
        guard let unit, !unit.isEmpty else { return n }
        // Symbols hug the number; words get a space.
        return unit.first!.isLetter ? "\(n) \(unit)" : "\(n)\(unit)"
    }
}

/// A one-click suggestion on a card: either a URL to open, or an `id` the agent performs when clicked.
struct CardAction: Codable, Equatable {
    let label: String
    var id: String?
    var url: String?
}

/// Shows cards that agents append as JSON lines to `AgentCards.inboxURL`.
@MainActor
final class AgentCards: ObservableObject {
    @Published private(set) var cards: [AgentCard] = []

    static let inboxURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Backchannel", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("cards.jsonl")
    }()

    private var offset: UInt64 = 0
    private var timer: Timer?
    /// Called for each new card as it arrives, and when the user rates one.
    var onShow: ((AgentCard) -> Void)?
    var onRate: ((AgentCard, Bool) -> Void)?

    func start() {
        // Skip anything already in the inbox from earlier sessions.
        offset = (try? FileManager.default.attributesOfItem(atPath: Self.inboxURL.path)[.size] as? UInt64) ?? 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.readInbox()
                self?.soundAlarm()
            }
        }
    }

    /// How often a warning sounds again until it's acknowledged.
    static let alarmInterval: TimeInterval = 10
    private var lastAlarm = Date.distantPast

    /// Like a stick shaker, a warning keeps sounding until someone acknowledges it.
    private func soundAlarm() {
        guard cards.contains(where: \.warning), Date().timeIntervalSince(lastAlarm) >= Self.alarmInterval else { return }
        lastAlarm = Date()
        NSSound(named: "Sosumi")?.play()
    }

    func dismiss(_ card: AgentCard) { cards.removeAll { $0.id == card.id } }

    func dismiss(_ some: [AgentCard]) {
        let ids = Set(some.map(\.id))
        cards.removeAll { ids.contains($0.id) }
    }

    /// How long a card stays on screen; hovering pauses the countdown. Warnings stay until acknowledged.
    static let lifetime: TimeInterval = 20

    private func onScreen(_ card: AgentCard) -> Bool { card.warning || Date().timeIntervalSince(card.shownAt) < Self.lifetime }

    /// Expands an advisory to show its details, with a fresh countdown so there's time to read them.
    func expand(_ card: AgentCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i].expanded = true
        cards[i].shownAt = Date()
    }

    /// Hotkey: closes the newest card on screen, acknowledging warnings first.
    func dismissNewest() {
        if let c = cards.last(where: \.warning) ?? cards.last(where: onScreen) { dismiss(c) }
    }

    /// Hotkey: opens the newest card on screen, warnings first; pressed again on that card, it closes it.
    /// With nothing on screen, it brings back the newest earlier card. So cards can be worked through by
    /// tapping one key, without leaving the conversation.
    func expandNewest() {
        if let c = cards.last(where: \.warning) ?? cards.last(where: onScreen) {
            c.expanded ? dismiss(c) : expand(c)
        } else if let c = cards.last {
            restore(c)
        }
    }

    /// Which levels' stacks of earlier cards are expanded into a list.
    @Published var openStacks: Set<AgentCard.Level> = []

    func toggleStack(_ level: AgentCard.Level) {
        if openStacks.contains(level) { openStacks.remove(level) } else { openStacks.insert(level) }
    }

    /// Brings a card back from the stack to the top, with a fresh countdown.
    func restore(_ card: AgentCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        var c = cards.remove(at: i)
        c.shownAt = Date()
        cards.append(c)
    }

    static let feedbackURL = inboxURL.deletingLastPathComponent().appendingPathComponent("card-feedback.jsonl")

    /// Records a thumbs up or down so the agent posting cards can learn what's useful.
    func rate(_ card: AgentCard, up: Bool) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }) else { return }
        cards[i].rating = up
        onRate?(card, up)
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "rating": up ? "up" : "down",
            "title": card.title,
            "headline": card.headline ?? "",
            "caption": card.caption ?? "",
            "source": card.source ?? "",
        ]
        Self.append(entry, to: Self.feedbackURL)
    }

    static let actionsURL = inboxURL.deletingLastPathComponent().appendingPathComponent("card-actions.jsonl")

    /// Runs a card's action: opens its URL directly, or hands its id to the agent via `actionsURL`.
    func perform(_ card: AgentCard) {
        guard let i = cards.firstIndex(where: { $0.id == card.id }), let action = card.action, !cards[i].actionTaken else { return }
        cards[i].actionTaken = true
        if let s = action.url, let url = URL(string: s) {
            NSWorkspace.shared.open(url)
            return
        }
        let entry: [String: Any] = [
            "time": ISO8601DateFormatter().string(from: Date()),
            "title": card.title,
            "action_id": action.id ?? "",
            "label": action.label,
        ]
        Self.append(entry, to: Self.actionsURL)
    }

    private static func append(_ entry: [String: Any], to url: URL) {
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(UInt8(ascii: "\n"))
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    /// Pauses a card's countdown by pushing its start time forward by the time spent hovered.
    func pause(_ id: UUID, for interval: TimeInterval) {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return }
        cards[i].shownAt += interval
    }

    /// How long an advisory lingers once the mouse leaves it after a peek.
    static let afterPeek: TimeInterval = 2

    /// Cuts a peeked-at advisory's countdown short, so it leaves soon after the mouse does. Clicked-open cards keep theirs.
    func hurry(_ id: UUID) {
        guard let i = cards.firstIndex(where: { $0.id == id }), !cards[i].expanded, !cards[i].warning else { return }
        cards[i].shownAt = min(cards[i].shownAt, Date() - Self.lifetime + Self.afterPeek)
    }

    private func readInbox() {
        guard let h = try? FileHandle(forReadingFrom: Self.inboxURL) else { return }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        if size < offset { offset = 0 }
        guard size > offset else { return }
        try? h.seek(toOffset: offset)
        guard let data = try? h.readToEnd() else { return }
        // Only consume complete lines; a partial write is picked up next tick.
        guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return }
        offset += UInt64(lastNewline - data.startIndex + 1)
        for line in data[..<lastNewline].split(separator: UInt8(ascii: "\n")) {
            if let card = try? JSONDecoder().decode(AgentCard.self, from: Data(line)) {
                cards.append(card)
                onShow?(card)
                // A new warning sounds right away, even if an earlier one just did.
                if card.warning { lastAlarm = .distantPast }
            }
        }
        cards = Array(cards.suffix(100))
    }
}

/// Screen regions occupied by cards, in the overlay's top-left coordinate space, and which one the
/// mouse is over. Hover comes from polling the mouse rather than `onHover`, because the panel ignores
/// mouse events away from the cards and so can miss the mouse leaving one.
@MainActor
final class CardRegions: ObservableObject {
    var rects: [UUID: CGRect] = [:]
    @Published var hovered: UUID?
}

/// A transparent panel that shows one level's cards in its own spot on screen: advisories bottom left,
/// cautions top right, warnings top center. It's click-through everywhere except over the cards, so their buttons work.
@MainActor
final class CardsOverlay {
    private let level: AgentCard.Level
    private var panel: NSPanel?
    private var timer: Timer?
    private var lastTick = Date()
    /// The advisory the mouse just left, and when.
    private var leftCard: (id: UUID, at: Date)?
    private let regions = CardRegions()
    private weak var cards: AgentCards?

    init(level: AgentCard.Level) { self.level = level }

    func show(cards: AgentCards) {
        self.cards = cards
        if panel == nil { panel = makePanel(cards: cards) }
        position()
        panel?.orderFrontRegardless()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateClickThrough() }
        }
    }

    func hide() {
        timer?.invalidate()
        panel?.orderOut(nil)
    }

    private func updateClickThrough() {
        guard let p = panel else { return }
        let m = NSEvent.mouseLocation
        let local = CGPoint(x: m.x - p.frame.minX, y: p.frame.maxY - m.y)
        let hovered = regions.rects.first { $0.value.contains(local) }?.key
        let overCard = hovered != nil
        if p.ignoresMouseEvents == overCard { p.ignoresMouseEvents = !overCard }
        let now = Date()
        if regions.hovered != hovered {
            if level == .advisory, let left = regions.hovered { leftCard = (left, now) }
            regions.hovered = hovered
        }
        // Only hurry a card once the mouse has stayed off it for a moment, so brushing past doesn't.
        if let (id, since) = leftCard {
            if hovered == id {
                leftCard = nil
            } else if now.timeIntervalSince(since) >= 1 {
                cards?.hurry(id)
                leftCard = nil
            }
        }
        if let hovered { cards?.pause(hovered, for: now.timeIntervalSince(lastTick)) }
        lastTick = now
    }

    private func makePanel(cards: AgentCards) -> NSPanel {
        let p = CardPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.isReleasedWhenClosed = false
        p.level = .statusBar
        p.ignoresMouseEvents = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = level == .warning ? AnyView(WarningCardsView()) : AnyView(CardsView(level: level))
        p.contentView = NSHostingView(rootView: root.environmentObject(cards).environmentObject(regions))
        return p
    }

    private func position() {
        guard let p = panel, let screen = NSScreen.main?.visibleFrame else { return }
        switch level {
        case .advisory:
            let size = NSSize(width: 400, height: screen.height - 32)
            p.setFrame(NSRect(x: screen.minX + 16, y: screen.minY + 16, width: size.width, height: size.height), display: true)
        case .caution:
            let size = NSSize(width: 400, height: screen.height - 32)
            p.setFrame(NSRect(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 16,
                              width: size.width, height: size.height), display: true)
        case .warning:
            let size = NSSize(width: 560, height: screen.height * 0.6)
            p.setFrame(NSRect(x: screen.midX - size.width / 2, y: screen.maxY - size.height - 16,
                              width: size.width, height: size.height), display: true)
        }
    }
}

/// Becomes key when a card is clicked, so ⌘↩ and Esc work on it, without activating the app.
/// It's only ever ordered front, never made key, when a card appears, so it doesn't steal focus.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Warnings, big and red at the top center of the screen. They don't fade, and they shake and sound
/// every `AgentCards.alarmInterval` until acknowledged.
struct WarningCardsView: View {
    @EnvironmentObject var cards: AgentCards
    @EnvironmentObject var regions: CardRegions

    var body: some View {
        let warnings = Array(cards.cards.filter(\.warning).reversed())
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 12) {
                ForEach(warnings) { card in
                    let shakes = Int(context.date.timeIntervalSince(card.shownAt) / AgentCards.alarmInterval)
                    CardView(card: card, age: 0, lifetime: .infinity,
                             rate: { cards.rate(card, up: $0) }, perform: { cards.perform(card) },
                             close: { cards.dismiss(card) })
                        .keyframeAnimator(initialValue: 0.0, trigger: shakes) { view, x in view.offset(x: x) } keyframes: { _ in
                            KeyframeTrack {
                                for x in [14.0, -12, 10, -8, 5, -3, 0] { SpringKeyframe(x, duration: 0.07) }
                            }
                        }
                        .background(cardFrameReader(card.id))
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.9, anchor: .top)),
                        removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
                Spacer(minLength: 0)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .coordinateSpace(name: "overlay")
            .onPreferenceChange(CardFrames.self) { regions.rects = $0 }
            .animation(.spring(response: 0.45, dampingFraction: 0.8), value: warnings.map(\.id))
        }
    }
}

/// Reports a card's frame in the overlay so the panel knows where to accept clicks.
private func cardFrameReader(_ id: UUID) -> some View {
    GeometryReader { g in
        Color.clear.preference(key: CardFrames.self, value: [id: g.frame(in: .named("overlay"))])
    }
}

/// One level's cards in its corner: cautions top right, advisories bottom left.
struct CardsView: View {
    let level: AgentCard.Level
    @EnvironmentObject var cards: AgentCards
    @EnvironmentObject var regions: CardRegions

    private let lifetime = AgentCards.lifetime
    /// Only the newest few show; older ones wait their turn until newer ones expire or are closed.
    private let maxShown = 3
    /// Advisories sit at the bottom of the screen, so they stack upward from the bottom edge.
    private var bottom: Bool { level == .advisory }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let mine = cards.cards.filter { $0.level == level }
            let live = Array(mine.filter { context.date.timeIntervalSince($0.shownAt) < lifetime })
            // Newest nearest the screen edge, so a new card always lands where there's room.
            let shown = Array(live.suffix(maxShown).reversed())
            let shownIDs = Set(shown.map(\.id))
            // Live cards waiting their turn collapse into a stack, newest first. Expired cards leave the
            // screen entirely; they're still in the transcript as research.
            let stacked = Array(live.filter { !shownIDs.contains($0.id) }.reversed())
            let open = cards.openStacks.contains(level)
            VStack(alignment: bottom ? .leading : .trailing, spacing: 12) {
                if bottom { Spacer(minLength: 0) }
                ForEach(bottom ? shown.reversed() : shown) { card in
                    CardView(card: card, age: context.date.timeIntervalSince(card.shownAt), lifetime: lifetime,
                             rate: { cards.rate(card, up: $0) }, perform: { cards.perform(card) },
                             close: { cards.dismiss(card) }, expand: { cards.expand(card) },
                             peek: regions.hovered == card.id)
                        .background(cardFrameReader(card.id))
                        .transition(.asymmetric(
                            insertion: .move(edge: bottom ? .leading : .trailing).combined(with: .opacity)
                                .combined(with: .scale(scale: 0.92, anchor: bottom ? .leading : .trailing)),
                            removal: .opacity.combined(with: .scale(scale: 0.96))))
                }
                if !stacked.isEmpty {
                    CardStack(cards: stacked, open: open, hovered: regions.hovered == CardStack.regionID,
                              toggle: { cards.toggleStack(level) },
                              restore: { cards.restore($0) },
                              close: { cards.dismiss($0) },
                              clear: { cards.dismiss(stacked) },
                              rate: { cards.rate($0, up: $1) },
                              perform: { cards.perform($0) })
                        .background(cardFrameReader(CardStack.regionID))
                        .transition(.opacity)
                }
                if !bottom { Spacer(minLength: 0) }
            }
            .padding(12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: bottom ? .bottomLeading : .topTrailing)
            .coordinateSpace(name: "overlay")
            .onPreferenceChange(CardFrames.self) { regions.rects = $0 }
            .animation(.spring(response: 0.45, dampingFraction: 0.85), value: live.map(\.id))
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: open)
            .animation(.spring(response: 0.35, dampingFraction: 0.85), value: live.map(\.expanded))
            .animation(.spring(response: 0.3, dampingFraction: 0.85), value: regions.hovered)
        }
    }
}

/// Earlier cards, collapsed into a small deck under the live ones. Click to fan them out into a list;
/// hover a row to see the whole card, click it to bring that card back to the top. Right-click to clear them all.
struct CardStack: View {
    static let regionID = UUID()

    let cards: [AgentCard]
    let open: Bool
    /// Whether the mouse is over the stack, from the overlay's polling; gates the rows' own hover.
    let hovered: Bool
    let toggle: () -> Void
    let restore: (AgentCard) -> Void
    let close: (AgentCard) -> Void
    let clear: () -> Void
    let rate: (AgentCard, Bool) -> Void
    let perform: (AgentCard) -> Void
    @State private var hovering = false
    /// The row under the mouse, shown as the full card.
    @State private var hoveredRow: UUID?

    private let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)

    var body: some View {
        VStack(spacing: 0) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "square.stack.3d.up.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(CardView.gradient(for: cards.first?.accent))
                    Text(open ? "Earlier cards" : (cards.first?.title ?? ""))
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text("\(cards.count)")
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.7))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.white.opacity(0.1), in: Capsule())
                    Image(systemName: open ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(RightClick(action: clear))
            .help("Click to list earlier cards; right-click to clear them")

            if open {
                Rectangle().fill(.white.opacity(0.07)).frame(height: 1)
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { i, card in
                            if i > 0 { Rectangle().fill(.white.opacity(0.05)).frame(height: 1) }
                            if hovered && hoveredRow == card.id {
                                full(card)
                            } else {
                                row(card)
                            }
                        }
                    }
                }
                .frame(maxHeight: 360)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.95), in: shape)
        .overlay(shape.strokeBorder(.white.opacity(0.1), lineWidth: 1))
        // Ghost edges peeking out underneath read as a deck of cards.
        .background(alignment: .bottom) {
            if !open {
                ZStack(alignment: .bottom) {
                    if cards.count > 2 { ghost.padding(.horizontal, 16).offset(y: 8) }
                    if cards.count > 1 { ghost.padding(.horizontal, 8).offset(y: 4) }
                }
            }
        }
        .shadow(color: .black.opacity(0.4), radius: 8, y: 3)
        .opacity(hovering || open ? 1 : 0.8)
        .onHover { hovering = $0 }
        .padding(.bottom, open ? 0 : 8)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hovered ? hoveredRow : nil)
        .onChange(of: hovered) { if !hovered { hoveredRow = nil } }
    }

    /// A stacked card opened up while hovered, with its details and buttons.
    private func full(_ card: AgentCard) -> some View {
        var c = card
        c.expanded = true
        return CardView(card: c, age: 0, lifetime: .infinity,
                        rate: { rate(card, $0) }, perform: { perform(card) }, close: { close(card) })
            .padding(8)
            .contentShape(Rectangle())
            .onTapGesture { restore(card) }
            .onHover { if !$0 && hoveredRow == card.id { hoveredRow = nil } }
            .help("Show this card again")
    }

    private var ghost: some View {
        shape.fill(Color(red: 0.09, green: 0.09, blue: 0.12).opacity(0.9))
            .overlay(shape.strokeBorder(.white.opacity(0.08), lineWidth: 1))
            .frame(height: 20)
    }

    private func row(_ card: AgentCard) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: card.icon ?? "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(CardView.gradient(for: card.accent), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(card.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
                if let headline = card.headline {
                    Text(headline)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.92))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 4)
            Text(card.shownAt, style: .time)
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.4))
            Button { close(card) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
            .help("Remove")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .onTapGesture { restore(card) }
        .onHover { if $0 { hoveredRow = card.id } }
        .help("Show this card again")
    }
}

/// Catches right-clicks and lets every other click through to the views underneath.
private struct RightClick: NSViewRepresentable {
    let action: () -> Void

    final class Catcher: NSView {
        var action: () -> Void = {}
        override func hitTest(_ point: NSPoint) -> NSView? {
            NSApp.currentEvent?.type == .rightMouseDown ? super.hitTest(point) : nil
        }
        override func rightMouseDown(with event: NSEvent) { action() }
    }

    func makeNSView(context: Context) -> Catcher { Catcher() }
    func updateNSView(_ view: Catcher, context: Context) { view.action = action }
}

private struct CardFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

struct CardView: View {
    let card: AgentCard
    let age: TimeInterval
    let lifetime: TimeInterval
    let rate: (Bool) -> Void
    let perform: () -> Void
    let close: () -> Void
    var expand: () -> Void = {}
    /// Whether the mouse is over the card, from the overlay's polling. A collapsed advisory opens up while it is.
    var peek = false
    @State private var hovering = false
    @State private var appeared = false
    /// Drives a warning's throbbing red glow.
    @State private var pulsing = false

    /// Urgent cards get bigger type.
    private var big: Bool { card.warning }
    private var hasDetails: Bool {
        card.caption != nil || !(card.rows ?? []).isEmpty || !(card.bars?.items ?? []).isEmpty || card.detail != nil || card.action != nil
    }

    private static let tints: [String: (Color, Color)] = [
        "violet": (Color(red: 0.55, green: 0.42, blue: 1.0), Color(red: 0.93, green: 0.36, blue: 0.85)),
        "blue": (Color(red: 0.25, green: 0.55, blue: 1.0), Color(red: 0.35, green: 0.85, blue: 1.0)),
        "green": (Color(red: 0.18, green: 0.80, blue: 0.55), Color(red: 0.55, green: 0.95, blue: 0.45)),
        "orange": (Color(red: 1.0, green: 0.55, blue: 0.20), Color(red: 1.0, green: 0.80, blue: 0.30)),
        "pink": (Color(red: 1.0, green: 0.35, blue: 0.60), Color(red: 1.0, green: 0.55, blue: 0.45)),
        "red": (Color(red: 1.0, green: 0.30, blue: 0.35), Color(red: 1.0, green: 0.50, blue: 0.30)),
        "teal": (Color(red: 0.15, green: 0.75, blue: 0.80), Color(red: 0.35, green: 0.60, blue: 1.0)),
    ]
    private var colors: (Color, Color) { Self.tints[card.accent ?? ""] ?? Self.tints["violet"]! }

    static func gradient(for tint: String?) -> LinearGradient {
        let c = tints[tint ?? ""] ?? tints["violet"]!
        return LinearGradient(colors: [c.0, c.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private var gradient: LinearGradient {
        LinearGradient(colors: [colors.0, colors.1], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    private let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
    /// A collapsed advisory shows just its headline, unless hovered.
    private var compactShown: Bool { card.collapsed && !(peek && hasDetails) }

    var body: some View {
        Group { if compactShown { compact } else { details } }
            .padding(compactShown ? 10 : (big ? 20 : 16))
            .padding(.bottom, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
            .overlay(alignment: .bottom) { if lifetime.isFinite { progressBar } }
            .clipShape(shape)
            .overlay(shape.strokeBorder(LinearGradient(colors: [colors.0.opacity(big ? 1 : 0.7), .white.opacity(0.10), colors.1.opacity(0.25)],
                                                       startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: big ? 2 : 1))
            .shadow(color: colors.0.opacity(big ? (pulsing ? 0.95 : 0.45) : (hovering ? 0.35 : 0.2)),
                    radius: big ? (pulsing ? 44 : 24) : (hovering ? 26 : 20), y: 8)
            .shadow(color: .black.opacity(0.45), radius: 10, y: 4)
            .scaleEffect(hovering ? 1.015 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.75), value: hovering)
            .onHover { hovering = $0 }
            .onAppear {
                if big { withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulsing = true } }
            }
            // Fade out over the last 5 seconds, interpolating between the once-a-second timeline ticks.
            .opacity(fade)
            .animation(.linear(duration: 1), value: fade)
    }

    /// An info card before it's expanded: one muted line with the title and headline. Hover to see the
    /// rest; click to keep it open.
    private var compact: some View {
        HStack(spacing: 9) {
            Image(systemName: card.icon ?? "sparkles")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(gradient.opacity(0.8), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Text(card.title)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
                .fixedSize()
            if let headline = card.headline {
                Text(headline)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 4)
            if hasDetails {
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white.opacity(hovering ? 0.8 : 0.45))
            }
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 16, height: 16)
                    .background(.white.opacity(0.1), in: Circle())
            }
            .buttonStyle(.plain)
            .opacity(hovering ? 1 : 0)
            .help("Close")
        }
        .contentShape(Rectangle())
        .onTapGesture { if hasDetails { expand() } }
        .help(hasDetails ? "Show details" : "")
        .opacity(hovering ? 1 : 0.8)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if card.headline != nil || card.caption != nil {
                VStack(alignment: .leading, spacing: 6) {
                    if let headline = card.headline {
                        // Short figures get the big display style; text headlines get a title size that wraps.
                        let figure = headline.count <= 10
                        Text(headline)
                            .font(figure ? .system(size: big ? 46 : 34, weight: .bold, design: .rounded)
                                         : .system(size: big ? 26 : 19, weight: .bold))
                            .monospacedDigit()
                            .lineSpacing(figure ? 0 : 1)
                            .foregroundStyle(LinearGradient(colors: [.white, .white.opacity(0.85)], startPoint: .top, endPoint: .bottom))
                            .shadow(color: colors.0.opacity(figure ? 0.45 : 0.3), radius: 12)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let caption = card.caption {
                        Text(caption)
                            .font(.system(size: big ? 15 : 13))
                            .lineSpacing(3)
                            .foregroundStyle(.white.opacity(0.85))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            if let rows = card.rows, !rows.isEmpty {
                // Short values (figures) right-align like a ledger; prose values get a left-aligned column.
                let prose = rows.contains { ($0.dropFirst().first ?? "").count > 22 }
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                        if i > 0 { Rectangle().fill(.white.opacity(0.07)).frame(height: 1) }
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(row.first ?? "")
                                .foregroundStyle(.white.opacity(0.6))
                                .frame(width: prose ? 92 : nil, alignment: .leading)
                                .fixedSize(horizontal: !prose, vertical: true)
                            if !prose { Spacer(minLength: 8) }
                            valueView(row.dropFirst().first ?? "", prose: prose)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .font(.system(size: 12.5))
                        .padding(.vertical, 7)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 3)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.06)))
            }

            if let bars = card.bars, !bars.items.isEmpty { barChart(bars) }

            if let detail = card.detail {
                Text(detail)
                    .font(.system(size: 12.5))
                    .lineSpacing(2.5)
                    .foregroundStyle(.white.opacity(0.88))
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let action = card.action { actionButton(action) }

            footer
        }
    }

    /// Horizontal bars scaled to the largest value, with the formatted value at each bar's end.
    private func barChart(_ bars: CardBars) -> some View {
        let maxValue = max(bars.items.map(\.value).max() ?? 0, .leastNonzeroMagnitude)
        let labelFont = NSFont.systemFont(ofSize: 12.5)
        let labelWidth = min(130, ceil(bars.items.map { ($0.label as NSString).size(withAttributes: [.font: labelFont]).width }.max() ?? 0))
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        let valueWidth = ceil(bars.items.map { (bars.format($0.value) as NSString).size(withAttributes: [.font: valueFont]).width }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 7) {
            ForEach(Array(bars.items.enumerated()), id: \.offset) { i, item in
                let emphasized = bars.highlight == nil || bars.highlight == i
                HStack(spacing: 10) {
                    Text(item.label)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.white.opacity(emphasized ? 0.9 : 0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: labelWidth, alignment: .leading)
                    GeometryReader { g in
                        let track = max(0, g.size.width - valueWidth - 8)
                        let width = max(3, track * max(0, item.value) / maxValue)
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(emphasized ? AnyShapeStyle(gradient) : AnyShapeStyle(colors.0.opacity(0.35)))
                                .frame(width: width)
                                .shadow(color: colors.0.opacity(emphasized && bars.highlight != nil ? 0.5 : 0), radius: 6)
                            Text(bars.format(item.value))
                                .font(.system(size: 12, weight: .semibold))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(emphasized ? 1 : 0.65))
                                .fixedSize()
                        }
                        .frame(height: g.size.height)
                    }
                    .frame(height: 16)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).strokeBorder(.white.opacity(0.06)))
    }

    /// The card's suggested action, on its own row so it stays clear of the thumbs.
    private func actionButton(_ action: CardAction) -> some View {
        let done = card.actionTaken
        let opens = action.url != nil
        return Button(action: perform) {
            HStack(spacing: 6) {
                Image(systemName: done ? "checkmark" : (opens ? "arrow.up.right" : "bolt.fill"))
                    .font(.system(size: 10, weight: .bold))
                Text(done ? (opens ? "Opened" : "Sent") : action.label)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(.white.opacity(done ? 0.6 : 1))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(done ? AnyShapeStyle(.white.opacity(0.08)) : AnyShapeStyle(gradient.opacity(0.85)), in: Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(done ? 0.08 : 0.25), lineWidth: 0.5))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(done)
        .help(opens ? (action.url ?? "") : "Ask the agent to do this")
    }

    private var footer: some View {
        HStack(spacing: 5) {
            if let source = card.source {
                Circle().fill(gradient).frame(width: 5, height: 5)
                Text(source.uppercased())
                    .font(.system(size: 9.5, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            thumb(up: true)
            thumb(up: false)
        }
    }

    private func thumb(up: Bool) -> some View {
        let chosen = card.rating == up
        return Button { rate(up) } label: {
            Image(systemName: up ? (chosen ? "hand.thumbsup.fill" : "hand.thumbsup")
                                 : (chosen ? "hand.thumbsdown.fill" : "hand.thumbsdown"))
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(chosen ? AnyShapeStyle(gradient) : AnyShapeStyle(.white.opacity(0.6)))
                .frame(width: 24, height: 22)
                .background(.white.opacity(chosen ? 0.14 : 0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .opacity(hovering || card.rating != nil ? 1 : 0.55)
        .help(up ? "Useful" : "Not useful")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: card.icon ?? (big ? "exclamationmark.triangle.fill" : "sparkles"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                .shadow(color: colors.0.opacity(0.6), radius: 8)
                .symbolEffect(.bounce, value: appeared)
            Text(big ? card.title.uppercased() : card.title)
                .font(.system(size: big ? 15 : 13.5, weight: big ? .bold : .semibold))
                .tracking(big ? 0.8 : 0)
                .foregroundStyle(.white)
                .lineLimit(2)
            Spacer(minLength: 4)
            if big { acknowledgeButton } else { closeButton }
        }
        .onAppear { appeared = true }
    }

    /// A warning keeps demanding attention until someone acknowledges it.
    private var acknowledgeButton: some View {
        Button(action: close) {
            Text("Acknowledge")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(gradient, in: Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.35), lineWidth: 0.5))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Acknowledge (⌃⌥⌘⎋)")
    }

    private var closeButton: some View {
        Button(action: close) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white.opacity(0.8))
                .frame(width: 20, height: 20)
                .background(.white.opacity(0.1), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(hovering ? 1 : 0)
        .help("Close")
    }

    private var background: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.09).opacity(0.97)
            // Soft colored glow from the top-left corner.
            RadialGradient(colors: [colors.0.opacity(0.32), .clear], center: .topLeading, startRadius: 0, endRadius: 260)
            RadialGradient(colors: [colors.1.opacity(0.12), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 220)
            // Top highlight for depth.
            LinearGradient(colors: [.white.opacity(0.06), .clear], startPoint: .top, endPoint: .center)
        }
    }

    /// Thin bar along the bottom edge showing time left; it pauses while hovered.
    private var progressBar: some View {
        GeometryReader { g in
            Rectangle()
                .fill(gradient)
                .frame(width: g.size.width * remaining)
                .animation(.linear(duration: 1), value: remaining)
        }
        .frame(height: 2.5)
        .opacity(0.85)
    }

    private var remaining: Double { min(1, max(0, (lifetime - age) / lifetime)) }
    private var fade: Double { min(1, max(0, (lifetime - age) / 5)) }

    /// Gains render as green pills and losses as red ones, so movement tables read at a glance.
    @ViewBuilder private func valueView(_ value: String, prose: Bool) -> some View {
        let v = value.trimmingCharacters(in: .whitespaces)
        let color: Color? = v.hasPrefix("+") ? Color(red: 0.4, green: 0.92, blue: 0.58)
            : (v.hasPrefix("-") || v.hasPrefix("−")) ? Color(red: 1, green: 0.48, blue: 0.5) : nil
        if let color {
            Text(v)
                .monospacedDigit()
                .fontWeight(.semibold)
                .foregroundStyle(color)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(color.opacity(0.14), in: Capsule())
        } else if prose {
            Text(v)
                .fontWeight(.medium)
                .foregroundStyle(.white.opacity(0.95))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text(v).monospacedDigit().fontWeight(.semibold).foregroundStyle(.white)
        }
    }
}
