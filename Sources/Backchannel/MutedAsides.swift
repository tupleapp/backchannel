import AVFoundation
import Foundation

/// While the local user is muted in Tuple, transcribes their mic on-device and hands each utterance to the
/// agent by appending `{"time","text"}` to `asides.jsonl`, so they can talk to Amp without the call hearing.
/// Transcribes with whisper.cpp (`whisper-cli`) and the same Whisper model Tuple downloads for its own
/// transcripts, which understands speech much better than Apple's recognizers.
@MainActor
final class MutedAsides: ObservableObject {
    @Published private(set) var listening = false
    /// Called with each finished utterance.
    var onAside: ((String, Date) -> Void)?
    /// Names to prime Whisper with, e.g. the people on the call.
    var names: () -> [String] = { [] }

    nonisolated static let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Backchannel/asides.jsonl")

    /// Words Whisper tends to mishear without a hint.
    private static let vocabulary = ["Tuple", "Amp", "orb", "Claude", "Backchannel", "Waymote", "Linear"]

    /// Whether the local user is in a call and muted.
    private let isMuted: () async -> Bool
    private var pollTask: Task<Void, Never>?
    private var micAllowed: Bool?
    private var lastMuted: Bool?
    private var starting = false

    private let engine = AVAudioEngine()
    private var segmenter: Segmenter?
    private let whisper = Whisper()

    init(isMuted: @escaping () async -> Bool) {
        self.isMuted = isMuted
    }

    func start() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let muted = await self.isMuted()
                if muted != self.lastMuted { self.lastMuted = muted; Self.debug("muted=\(muted)") }
                if muted && !self.listening && !self.starting { await self.begin() }
                else if !muted && self.listening { self.end() }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func begin() async {
        starting = true
        defer { starting = false }
        if micAllowed == nil {
            micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            Self.debug("mic allowed=\(micAllowed!)")
        }
        guard micAllowed == true else { return }
        guard whisper.ready else {
            Self.debug("whisper unavailable: cli=\(Whisper.cli ?? "missing") model=\(Whisper.model ?? "missing")")
            return
        }

        let mic = engine.inputNode
        // Echo cancellation, so call audio leaking from headphones or speakers into the mic is
        // removed like it is in Tuple, without turning other apps' audio down.
        do {
            try mic.setVoiceProcessingEnabled(true)
            mic.voiceProcessingOtherAudioDuckingConfiguration =
                AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
        } catch {
            Self.debug("voice processing unavailable: \(error.localizedDescription)")
        }
        let micFormat = mic.outputFormat(forBus: 0)
        guard let converter = Converter(from: micFormat, to: Segmenter.format) else { Self.debug("no converter"); return }
        let segmenter = Segmenter { [weak self] samples, startedAt in
            Task { @MainActor in self?.transcribe(samples, startedAt: startedAt) }
        }
        self.segmenter = segmenter
        mic.removeTap(onBus: 0)
        mic.installTap(onBus: 0, bufferSize: 4096, format: micFormat) { buffer, _ in
            if let converted = converter.convert(buffer) { segmenter.feed(converted) }
        }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            Self.debug("engine failed: \(error.localizedDescription)")
            mic.removeTap(onBus: 0)
            return
        }
        listening = true
        Self.debug("listening, mic=\(micFormat)")
    }

    private func end() {
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        segmenter?.flush()
        segmenter = nil
        listening = false
        Self.debug("stopped")
    }

    private func transcribe(_ samples: [Float], startedAt: Date) {
        let prompt = (Self.vocabulary + names()).joined(separator: ", ")
        whisper.transcribe(samples, prompt: prompt) { [weak self] text in
            Task { @MainActor in
                guard let self, let text = Self.clean(text) else { return }
                self.append(text, time: startedAt)
                self.onAside?(text, startedAt)
            }
        }
    }

    /// Whisper's usual output on silence or noise, which isn't anything the user said.
    private static let hallucinations: Set<String> = [
        "thank you", "thanks", "thank you very much", "thanks for watching", "thank you for watching",
        "you", "bye", "okay", "blank audio", "silence", "music", "inaudible", "no audio",
    ]

    private static func clean(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.contains(where: \.isLetter) else { return nil }
        if text.hasPrefix("[") && text.hasSuffix("]") { return nil }
        if text.hasPrefix("(") && text.hasSuffix(")") { return nil }
        let words = text.lowercased().components(separatedBy: CharacterSet.letters.union(.whitespaces).inverted).joined()
            .split(separator: " ").joined(separator: " ")
        return hallucinations.contains(words) ? nil : text
    }

    private func append(_ text: String, time: Date) {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard var data = try? JSONSerialization.data(withJSONObject: ["time": f.string(from: time), "text": text],
                                                     options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        data.append(UInt8(ascii: "\n"))
        let url = Self.url
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(data)
            try? h.close()
        } else {
            try? data.write(to: url)
        }
    }

    nonisolated static func debug(_ msg: String) {
        let url = url.deletingLastPathComponent().appendingPathComponent("asides-debug.log")
        let line = Data("\(Date()) \(msg)\n".utf8)
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(line); try? h.close() }
        else { try? line.write(to: url) }
    }
}

/// Splits 16 kHz mono audio into utterances by loudness: speech starts when a buffer is clearly louder than
/// the background, and ends after a second of quiet. Runs on the audio thread.
private final class Segmenter: @unchecked Sendable {
    static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!

    private let rate = 16_000.0
    /// Quiet that ends an utterance, the longest utterance, and the least speech worth transcribing.
    private let endSilence = 1.0, maxLength = 30.0, minSpeech = 0.4
    /// Audio kept from just before speech starts, so the first syllable isn't clipped.
    private let preRoll = 0.3

    private let lock = NSLock()
    private let emit: ([Float], Date) -> Void
    private var noiseFloor: Float = 0.005
    private var recent: [Float] = []
    private var utterance: [Float] = []
    private var startedAt: Date?
    private var voiced = 0.0, silence = 0.0
    private var peak: Float = 0, sinceLog = 0.0

    init(emit: @escaping ([Float], Date) -> Void) {
        self.emit = emit
    }

    func feed(_ buffer: AVAudioPCMBuffer) {
        guard let data = buffer.floatChannelData?[0] else { return }
        let samples = Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength)))
        guard !samples.isEmpty else { return }
        let rms = (samples.reduce(0) { $0 + $1 * $1 } / Float(samples.count)).squareRoot()
        let seconds = Double(samples.count) / rate
        let loud = rms > max(0.001, noiseFloor * 4)

        lock.lock()
        defer { lock.unlock() }
        // Log the input level every 5 s so a threshold that's too high for this mic is easy to spot.
        peak = max(peak, rms)
        sinceLog += seconds
        if sinceLog >= 5 {
            MutedAsides.debug(String(format: "level peak=%.4f floor=%.4f threshold=%.4f", peak, noiseFloor, max(0.001, noiseFloor * 4)))
            peak = 0
            sinceLog = 0
        }
        if startedAt == nil {
            // Track the background level while nobody is speaking.
            noiseFloor = noiseFloor * 0.95 + rms * 0.05
            recent.append(contentsOf: samples)
            if recent.count > Int(preRoll * rate) { recent.removeFirst(recent.count - Int(preRoll * rate)) }
            guard loud else { return }
            startedAt = Date().addingTimeInterval(-Double(recent.count) / rate)
            utterance = recent
            recent = []
            voiced = 0
            silence = 0
        }
        utterance.append(contentsOf: samples)
        if loud { voiced += seconds; silence = 0 } else { silence += seconds }
        if silence >= endSilence || Double(utterance.count) / rate >= maxLength { finish() }
    }

    /// Ends the utterance in progress, e.g. on unmute.
    func flush() {
        lock.lock()
        defer { lock.unlock() }
        if startedAt != nil { finish() }
    }

    private func finish() {
        if voiced >= minSpeech, let startedAt {
            // Voice processing leaves the mic very quiet; bring the clip up to a normal level for Whisper.
            let top = utterance.reduce(0) { max($0, abs($1)) }
            emit(top > 0 ? utterance.map { $0 * min(0.9 / top, 200) } : utterance, startedAt)
        }
        utterance = []
        startedAt = nil
    }
}

/// Runs `whisper-cli` with Tuple's Whisper model on one utterance at a time.
private final class Whisper: @unchecked Sendable {
    static let cli = ["/opt/homebrew/bin/whisper-cli", "/usr/local/bin/whisper-cli"]
        .first { FileManager.default.isExecutableFile(atPath: $0) }

    /// The model Tuple downloads for its own transcripts, from the production app or else staging or dev.
    static let model: String? = {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return ["Tuple", "TupleStaging", "TupleDev"]
            .map { support.appendingPathComponent("\($0)/Transcription Models/ggml-large-v3-turbo-q5_0.bin").path }
            .first { FileManager.default.fileExists(atPath: $0) }
    }()

    var ready: Bool { Self.cli != nil && Self.model != nil }

    private let queue = DispatchQueue(label: "app.tuple.backchannel.whisper")

    func transcribe(_ samples: [Float], prompt: String, done: @escaping @Sendable (String) -> Void) {
        guard let cli = Self.cli, let model = Self.model else { return }
        queue.async {
            let wav = FileManager.default.temporaryDirectory.appendingPathComponent("aside-\(UUID().uuidString).wav")
            defer { try? FileManager.default.removeItem(at: wav) }
            guard (try? Self.wavData(samples).write(to: wav)) != nil else { return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: cli)
            p.arguments = ["-m", model, "-f", wav.path, "-nt", "-np", "-l", "en", "--prompt", prompt]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            let started = Date()
            guard (try? p.run()) != nil else { MutedAsides.debug("whisper failed to run"); return }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
                .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            MutedAsides.debug(String(format: "whisper %.1fs audio in %.1fs: %@",
                                     Double(samples.count) / 16_000, Date().timeIntervalSince(started), text))
            done(text)
        }
    }

    /// 16-bit mono 16 kHz WAV.
    private static func wavData(_ samples: [Float]) -> Data {
        var pcm = Data(capacity: samples.count * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s)) * Float(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }
        var d = Data()
        func put<T>(_ value: T) { var v = value; withUnsafeBytes(of: &v) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); put(UInt32(36 + pcm.count).littleEndian)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); put(UInt32(16).littleEndian)
        put(UInt16(1).littleEndian); put(UInt16(1).littleEndian)
        put(UInt32(16_000).littleEndian); put(UInt32(32_000).littleEndian)
        put(UInt16(2).littleEndian); put(UInt16(16).littleEndian)
        d.append(contentsOf: Array("data".utf8)); put(UInt32(pcm.count).littleEndian)
        d.append(pcm)
        return d
    }
}

/// Converts mic buffers to the segmenter's format on the audio thread.
private final class Converter: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let output: AVAudioFormat

    init?(from: AVAudioFormat, to: AVAudioFormat) {
        guard let c = AVAudioConverter(from: from, to: to) else { return nil }
        // Use only the first input channel, like Tuple does.
        if from.channelCount > 1 { c.channelMap = (0..<Int(to.channelCount)).map { _ in NSNumber(value: 0) } }
        converter = c
        output = to
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let ratio = output.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let out = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buffer
        }
        return error == nil && out.frameLength > 0 ? out : nil
    }
}
