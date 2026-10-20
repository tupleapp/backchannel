import AppKit
import Carbon
import Combine
import SwiftUI

@main
struct BackchannelApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        // Everything lives in floating panels owned by the app delegate.
        Settings { EmptyView() }
    }
}

/// Owns the long-lived services so they run no matter which windows macOS restores.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let stream = TranscriptStream()
    let transcript = TranscriptPanel()
    let cards = AgentCards()
    /// Like a cockpit, each alert level has its own place on screen.
    let cardsOverlays = [CardsOverlay(level: .advisory), CardsOverlay(level: .caution), CardsOverlay(level: .warning)]
    let hotkeys = Hotkeys()
    private var keyMonitor: Any?
    lazy var asides = MutedAsides { [weak self] in await self?.stream.localMuted() ?? false }
    private var callState: AnyCancellable?
    private var asideState: AnyCancellable?

    func applicationWillFinishLaunching(_ notification: Notification) {
        // Always open fresh windows instead of restoring whichever ones were open last time.
        UserDefaults.standard.set(false, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        stream.start()
        // Cards the agent shows are kept in the transcript as its research, unless thumbed down.
        cards.onShow = { [weak self] in self?.stream.addResearch($0) }
        cards.onRate = { [weak self] card, up in if !up { self?.stream.removeResearch(card) } }
        cards.start()
        cardsOverlays.forEach { $0.show(cards: cards) }
        setUpCardKeys()
        // While muted in Tuple, what the local user says goes privately to the agent.
        asides.onAside = { [weak self] text, time in self?.stream.addAside(text, time: time) }
        asides.names = { [weak self] in self?.stream.speakerSlots.keys.filter { !$0.contains("→") } ?? [] }
        asideState = asides.$listening.sink { [weak self] in self?.stream.talkingToAgent = $0 }
        asides.start()
        showTranscript()
        callState = stream.$inCall.compactMap { $0 }.removeDuplicates().sink { [weak self] inCall in
            inCall ? self?.callStarted() : self?.callEnded()
        }
    }

    // Stay running between calls so windows come back when the next call starts.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func callStarted() {
        NSApp.setActivationPolicy(.regular)
        cardsOverlays.forEach { $0.show(cards: cards) }
        showTranscript()
    }

    private func callEnded() {
        transcript.hide()
        cardsOverlays.forEach { $0.hide() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// Work through cards from the keyboard: ⌘↩ opens the newest card and, pressed again, closes it; Esc closes it.
    /// Those plain keys work once a card has been clicked. ⌃⌥⌘↩ and ⌃⌥⌘⎋ do the same from any app.
    private func setUpCardKeys() {
        hotkeys.register(kVK_Return) { [weak self] in self?.cards.expandNewest() }
        hotkeys.register(kVK_Escape) { [weak self] in self?.cards.dismissNewest() }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window is CardPanel else { return event }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            switch Int(event.keyCode) {
            case kVK_Return where mods == .command: cards.expandNewest()
            case kVK_Escape where mods.isEmpty: cards.dismissNewest()
            default: return event
            }
            return nil
        }
    }

    private func showTranscript() {
        transcript.show(TranscriptBubble(content: TranscriptView()).environmentObject(stream))
    }
}

struct TranscriptView: View {
    @EnvironmentObject var stream: TranscriptStream
    @State private var followTail = true
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var fontSize: CGFloat = 13

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(Array(stream.lines.enumerated()), id: \.element.id) { i, line in
                            LineRow(line: line, fontSize: fontSize, continued: continues(i),
                                    color: speakerColor(line.speaker))
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(10)
                    .textSelection(.enabled)
                }
                .onChange(of: stream.lines) {
                    if followTail { withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom") } }
                }
                // Scrolling up turns autoscroll off; scrolling back to the bottom turns it on again.
                // Only user scrolls count, so new lines arriving or autoscroll itself don't flip it.
                .onScrollPhaseChange { _, phase in scrollPhase = phase }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 30
                } action: { _, atBottom in
                    if [.tracking, .interacting, .decelerating].contains(scrollPhase) { followTail = atBottom }
                }
                // The panel rebuilds this view on every expand, so start at the latest line.
                .onAppear {
                    // Scroll again once the panel's expand animation and layout have settled.
                    for delay in [0.0, 0.25, 0.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            Divider()
            HStack(spacing: 10) {
                if stream.talkingToAgent {
                    Image(systemName: "mic.fill").font(.caption).foregroundStyle(.purple)
                    Text("Muted — talking to Amp").font(.caption).foregroundStyle(.purple).lineLimit(1)
                } else {
                    Circle().fill(stream.status == "Live" ? .green : .orange).frame(width: 8, height: 8)
                    Text(stream.status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Toggle("Autoscroll", isOn: $followTail).toggleStyle(.checkbox).font(.caption)
                Button { fontSize = max(10, fontSize - 1) } label: { Image(systemName: "textformat.size.smaller") }
                Button { fontSize = min(24, fontSize + 1) } label: { Image(systemName: "textformat.size.larger") }
                Button { stream.clear() } label: { Image(systemName: "trash") }.help("Clear")
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }

    private func speakerColor(_ speaker: String?) -> Color {
        let palette: [Color] = [.blue, .orange, .purple, .green, .pink, .teal, .red, .indigo, .yellow, .brown, .mint, .cyan]
        guard let slot = speaker.flatMap({ stream.speakerSlots[$0] }) else { return .secondary }
        // Past the palette, rotate hue so extra speakers still get distinct colors.
        return slot < palette.count ? palette[slot] : Color(hue: Double(slot) * 0.618.truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.8)
    }

    /// True when the line directly follows speech by the same speaker, so the name can be omitted.
    private func continues(_ i: Int) -> Bool {
        guard i > 0 else { return false }
        let prev = stream.lines[i - 1], cur = stream.lines[i]
        return cur.kind == .speech && prev.kind == .speech && prev.speaker == cur.speaker
    }
}

/// A card the agent showed, kept compactly in the transcript and flagged as its research.
struct ResearchRow: View {
    let research: Research
    let fontSize: CGFloat
    let time: String
    @State private var expanded = false

    var body: some View {
        let gradient = CardView.gradient(for: research.tint)
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: research.icon ?? "sparkles")
                .font(.system(size: fontSize - 3, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(gradient, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("RESEARCH · AMP").fontWeight(.semibold).tracking(0.5).foregroundStyle(gradient)
                    Text(time).foregroundStyle(.tertiary)
                }
                .font(.system(size: fontSize - 4))
                Text(research.title).font(.system(size: fontSize - 1, weight: .semibold))
                if let headline = research.headline {
                    Text(headline).font(.system(size: fontSize - 1)).foregroundStyle(.secondary)
                }
                if let caption = research.caption {
                    Text(caption)
                        .font(.system(size: fontSize - 2))
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 2)
                        .onTapGesture { expanded.toggle() }
                        .help(expanded ? "Click to collapse" : "Click to expand")
                }
                if let source = research.source {
                    Text("via \(source)").font(.system(size: fontSize - 4)).foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: 8).fill(gradient).frame(width: 3)
        }
    }
}

struct LineRow: View {
    let line: Line
    let fontSize: CGFloat
    var continued = false
    var color: Color = .primary

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm:ss"
        return f
    }()

    var body: some View {
        switch line.kind {
        case .event:
            Text("— \(line.text) · \(Self.clock.string(from: line.time))")
                .font(.system(size: fontSize - 2))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, alignment: .center)
        case .research:
            if let r = line.research { ResearchRow(research: r, fontSize: fontSize, time: Self.clock.string(from: line.time)) }
        case .speech where continued:
            Text(line.text).font(.system(size: fontSize)).padding(.top, -4)
        case .speech:
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(line.speaker ?? "Unknown").fontWeight(.semibold).foregroundStyle(color)
                    Text(Self.clock.string(from: line.time)).foregroundStyle(.tertiary).font(.system(size: fontSize - 3))
                }
                .font(.system(size: fontSize - 1))
                Text(line.text).font(.system(size: fontSize))
            }
        }
    }
}
