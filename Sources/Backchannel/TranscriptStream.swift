import Foundation

struct Line: Identifiable, Equatable {
    enum Kind { case speech, event, research }
    let id: Int
    let kind: Kind
    let speaker: String?
    let text: String
    let time: Date
    /// For `.research` lines: the card the agent showed.
    var research: Research?
}

/// A card the agent showed during the call, kept in the transcript as research it did.
/// Persisted per call to `research-<call-id>.jsonl`.
struct Research: Codable, Equatable {
    var kind = "research"
    var by = "amp"
    let id: String
    let time: Date
    let title: String
    var headline: String?
    var caption: String?
    var source: String?
    var icon: String?
    var tint: String?

    init(card: AgentCard) {
        id = card.id.uuidString
        time = card.shownAt
        title = card.title
        headline = card.headline
        caption = card.caption
        source = card.source
        icon = card.icon
        tint = card.accent
    }
}

/// Runs `tuple capture follow` and turns its JSON lines into transcript lines.
@MainActor
final class TranscriptStream: ObservableObject {
    @Published private(set) var lines: [Line] = []
    @Published private(set) var status = "Starting…"
    /// Palette index per speaker, assigned in order of first appearance so names never share a color.
    @Published private(set) var speakerSlots: [String: Int] = [:]
    /// Whether a call is active; nil until the stream has caught up.
    @Published private(set) var inCall: Bool?
    /// True while the local user is muted and their speech goes privately to the agent.
    @Published var talkingToAgent = false

    /// Call state seen during catch-up, published once the stream is live.
    private var pendingInCall = false
    private var caughtUp = false

    private var process: Process?
    private var buffer = Data()
    private var lastID: Int?
    private var restartTask: Task<Void, Never>?

    private var probeTask: Task<Void, Never>?

    /// The current call's ID, used to name its research file.
    private var callID: String?
    /// Research the agent did in the current call, oldest first.
    private var research: [Research] = []
    /// Research lines get negative IDs so they never clash with capture record IDs.
    private var nextResearchLineID = -1

    /// A Tuple daemon to follow: its socket and the matching `--env` for the CLI.
    struct Target: Equatable, Sendable {
        let host: String
        let env: String?
    }

    private let tuplePath: String
    /// Daemons to watch, in order of preference when more than one is in a call.
    private let candidates: [Target]
    private var target: Target

    init() {
        let env = ProcessInfo.processInfo.environment
        tuplePath = env["TUPLE_BIN"] ?? "/usr/local/bin/tuple"
        if let host = env["TUPLE_HOST"] {
            candidates = [Target(host: host, env: env["TUPLE_ENV"])]
        } else if let e = env["TUPLE_ENV"], e != "prod" {
            candidates = [Target(host: "/tmp/tuple.\(e).sock", env: e)]
        } else {
            // No override: watch the dev, staging and production apps and follow whichever is in a call.
            candidates = [Target(host: "/tmp/tuple.dev.sock", env: "dev"),
                          Target(host: "/tmp/tuple.staging.sock", env: "staging"),
                          Target(host: "/tmp/tuple.sock", env: "prod")]
        }
        target = Self.firstInCall(candidates, tuplePath: tuplePath) ?? candidates.last!
        if candidates.count > 1 { startProbing() }
    }

    /// While the followed daemon isn't in a call, check the others and switch to one that is.
    private func startProbing() {
        probeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.inCall != true else { continue }
                let candidates = self.candidates, path = self.tuplePath
                let found = await Task.detached { Self.firstInCall(candidates, tuplePath: path) }.value
                if let found, found != self.target { self.switchTo(found) }
            }
        }
    }

    private func switchTo(_ t: Target) {
        target = t
        lastID = nil
        lines.removeAll()
        speakerSlots.removeAll()
        setCall(nil)
        start()
    }

    nonisolated private static func firstInCall(_ targets: [Target], tuplePath: String) -> Target? {
        targets.first { state(of: $0, tuplePath: tuplePath)?["in_call"] as? Bool == true }
    }

    nonisolated private static func state(of t: Target, tuplePath: String) -> [String: Any]? {
        guard FileManager.default.fileExists(atPath: t.host) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tuplePath)
        p.arguments = ["-H", t.host] + (t.env.map { ["--env", $0] } ?? []) + ["--format", "json", "state"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// Whether the local user is in a call on the followed daemon and muted.
    func localMuted() async -> Bool {
        guard inCall == true else { return false }
        let t = target, path = tuplePath
        let state = await Task.detached { Self.state(of: t, tuplePath: path) }.value
        return (state?["call"] as? [String: Any])?["muted"] as? Bool == true
    }

    func start() {
        stop()
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tuplePath)
        var args = ["-H", target.host] + (target.env.map { ["--env", $0] } ?? [])
        args += ["--format", "json", "capture", "follow"]
        if let lastID { args += ["--cursor", String(lastID)] }
        p.arguments = args

        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        out.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            Task { @MainActor in self?.ingest(chunk) }
        }
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.scheduleRestart() }
        }

        do {
            try p.run()
            process = p
            status = "Connecting…"
        } catch {
            status = "Couldn't run \(tuplePath): \(error.localizedDescription)"
            scheduleRestart()
        }
    }

    func stop() {
        restartTask?.cancel()
        if let p = process {
            p.terminationHandler = nil
            (p.standardOutput as? Pipe)?.fileHandleForReading.readabilityHandler = nil
            if p.isRunning { p.terminate() }
        }
        process = nil
        buffer.removeAll()
    }

    func clear() { lines.removeAll() }

    private func scheduleRestart() {
        status = "Disconnected — retrying…"
        process = nil
        restartTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            self?.start()
        }
    }

    private func ingest(_ chunk: Data) {
        buffer.append(chunk)
        while let nl = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<nl]
            buffer.removeSubrange(buffer.startIndex...nl)
            if let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any] {
                handle(obj)
            }
        }
    }

    private func handle(_ r: [String: Any]) {
        // Stream framing arrives as {"kind":"status","status":"caught_up"}; capture records use "type".
        let type = r["type"] as? String ?? r["status"] as? String ?? ""
        let data = r["data"] as? [String: Any] ?? [:]
        let id = r["id"] as? Int ?? 0
        if id > 0 { lastID = max(lastID ?? 0, id) }

        switch type {
        case "stream_opened":
            status = "Connected"
            caughtUp = false
            pendingInCall = r["call_id"] != nil
            setCall(r["call_id"] as? String)
            return
        case "caught_up":
            status = "Live"
            caughtUp = true
            inCall = pendingInCall
            return
        case "call_started":
            status = "Live"
            if caughtUp {
                lines.removeAll()
                speakerSlots.removeAll()
                setCall(nil)
                inCall = true
            } else {
                pendingInCall = true
            }
        case "call_ended":
            status = "Call ended — waiting for next call"
            if caughtUp { inCall = false } else { pendingInCall = false }
        default: break
        }
        if callID == nil, let id = (data["call_id"] as? String) ?? Self.uuid(in: data["message"] as? String) { setCall(id) }

        let time = parseDate(data["start"] as? String) ?? parseDate(r["time"] as? String) ?? Date()

        if type == "transcription_finished" {
            guard let text = Cleaner.clean(data["text"] as? String ?? "") else { return }
            insert(Line(id: id, kind: .speech, speaker: data["speaker"] as? String, text: text, time: time))
        } else if ["user_joined", "user_left", "call_started", "call_ended", "recording_started", "recording_ended"].contains(type) {
            let who = (data["user"] as? [String: Any])?["full_name"] as? String
            let label = type.replacingOccurrences(of: "_", with: " ")
            insert(Line(id: id, kind: .event, speaker: nil, text: who.map { "\($0) \(label.replacingOccurrences(of: "user ", with: ""))" } ?? label, time: time))
        }
    }

    /// Transcripts arrive slightly out of order, so keep lines sorted by spoken time.
    private func insert(_ line: Line) {
        if line.id > 0, lines.contains(where: { $0.id == line.id }) { return }
        if let who = line.speaker, speakerSlots[who] == nil { speakerSlots[who] = speakerSlots.count }
        let idx = lines.lastIndex(where: { $0.time <= line.time }).map { $0 + 1 } ?? 0
        lines.insert(line, at: idx)
    }

    /// Shows something the local user said privately to the agent while muted.
    func addAside(_ text: String, time: Date) {
        insert(Line(id: nextResearchLineID, kind: .speech, speaker: "You → Amp", text: text, time: time))
        nextResearchLineID -= 1
    }

    // MARK: Research

    private static let researchDir = AgentCards.inboxURL.deletingLastPathComponent()

    private func researchURL(_ id: String) -> URL { Self.researchDir.appendingPathComponent("research-\(id).jsonl") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    /// Switches to a call's research, loading what was kept from earlier in it, and shows it in the transcript.
    private func setCall(_ id: String?) {
        if id != callID {
            callID = id
            research = []
            if let id, let data = try? Data(contentsOf: researchURL(id)) {
                let d = JSONDecoder()
                d.dateDecodingStrategy = .iso8601
                research = data.split(separator: UInt8(ascii: "\n")).compactMap { try? d.decode(Research.self, from: Data($0)) }
            }
        }
        research.forEach(insertResearch)
    }

    /// Records a card the agent showed as research in the transcript.
    func addResearch(_ card: AgentCard) {
        // Skip test cards.
        let words = card.title.lowercased().split { !$0.isLetter }
        if words.contains("test") { return }
        let r = Research(card: card)
        research.append(r)
        insertResearch(r)
        saveResearch()
    }

    /// Drops a card the user thumbed down from the transcript and the research file.
    func removeResearch(_ card: AgentCard) {
        let id = card.id.uuidString
        research.removeAll { $0.id == id }
        lines.removeAll { $0.research?.id == id }
        saveResearch()
    }

    private func insertResearch(_ r: Research) {
        guard !lines.contains(where: { $0.research?.id == r.id }) else { return }
        insert(Line(id: nextResearchLineID, kind: .research, speaker: nil, text: r.title, time: r.time, research: r))
        nextResearchLineID -= 1
    }

    private func saveResearch() {
        guard let callID else { return }
        let url = researchURL(callID)
        if research.isEmpty { try? FileManager.default.removeItem(at: url); return }
        var out = Data()
        for r in research {
            guard let d = try? Self.encoder.encode(r) else { continue }
            out.append(d)
            out.append(UInt8(ascii: "\n"))
        }
        try? out.write(to: url, options: .atomic)
    }

    private static func uuid(in s: String?) -> String? {
        guard let s, let r = s.range(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}", options: .regularExpression) else { return nil }
        return String(s[r])
    }

    private func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
}
