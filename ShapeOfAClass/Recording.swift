import Foundation
import AVFoundation
import Speech
import Observation

// MARK: - Model

struct ClassEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case phase, track }
    var id = UUID()
    let kind: Kind
    let time: TimeInterval
    let title: String
    var detail: String = ""
}

struct Cue: Codable, Hashable, Identifiable {
    var id = UUID()
    let start: TimeInterval
    let end: TimeInterval
    let text: String
}

enum TranscriptStatus: String, Codable {
    case pending, working, done, failed, denied
}

struct RecordedClass: Codable, Hashable, Identifiable {
    var id = UUID()
    var date: Date
    var week: Int
    var theme: String
    var length: ClassLength
    var duration: TimeInterval
    var audioFile: String
    var events: [ClassEvent]
    var cues: [Cue] = []
    var transcript: TranscriptStatus = .pending
    var video: Bool? = nil

    var isVideo: Bool { video == true }

    func event(_ kind: ClassEvent.Kind, at t: TimeInterval) -> ClassEvent? {
        events.last { $0.kind == kind && $0.time <= t + 0.01 }
    }

    func cueID(at t: TimeInterval) -> UUID? {
        cues.last { $0.start <= t }?.id
    }

    var cueSheet: String {
        var lines: [String] = []
        lines.append("THE SHAPE OF A CLASS")
        lines.append("Week \(week): \(theme) · \(length.label) · \(date.formatted(date: .abbreviated, time: .shortened))")
        lines.append("")
        enum Item { case event(ClassEvent), cue(Cue) }
        let items: [(TimeInterval, Item)] = events.map { ($0.time, .event($0)) } + cues.map { ($0.start, .cue($0)) }
        for (time, item) in items.sorted(by: { $0.0 < $1.0 }) {
            let stamp = "[\(Fmt.clock(time))]"
            switch item {
            case .event(let e) where e.kind == .phase:
                lines.append("")
                lines.append("\(stamp) \(e.title.uppercased())  \(e.detail)")
            case .event(let e):
                lines.append("\(stamp) ♪ \(e.title)\(e.detail.isEmpty ? "" : " — \(e.detail)")")
            case .cue(let c):
                lines.append("\(stamp) \(c.text)")
            }
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Store

@Observable
final class RecordingStore {
    private(set) var recordings: [RecordedClass] = []
    private let indexURL: URL

    static var directory: URL {
        let dir = URL.documentsDirectory.appending(path: "Recordings", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    init() {
        indexURL = RecordingStore.directory.appending(path: "index.json")
        if let data = try? Data(contentsOf: indexURL),
           let decoded = try? JSONDecoder().decode([RecordedClass].self, from: data) {
            recordings = decoded.map { r in
                var r = r
                if r.transcript == .working { r.transcript = .failed }
                return r
            }
        }
    }

    func recording(_ id: UUID) -> RecordedClass? {
        recordings.first { $0.id == id }
    }

    func audioURL(_ r: RecordedClass) -> URL {
        RecordingStore.directory.appending(path: r.audioFile)
    }

    func add(_ r: RecordedClass) {
        recordings.insert(r, at: 0)
        persist()
    }

    func update(_ r: RecordedClass) {
        guard let i = recordings.firstIndex(where: { $0.id == r.id }) else { return }
        recordings[i] = r
        persist()
    }

    func delete(_ r: RecordedClass) {
        try? FileManager.default.removeItem(at: audioURL(r))
        recordings.removeAll { $0.id == r.id }
        persist()
    }

    @MainActor
    func transcribe(_ id: UUID) async {
        guard var r = recording(id) else { return }
        r.transcript = .working
        update(r)
        guard await Transcriber.authorize() else {
            r.transcript = .denied
            update(r)
            return
        }
        do {
            if r.isVideo {
                let audio = try await Transcriber.extractAudio(from: audioURL(r))
                defer { try? FileManager.default.removeItem(at: audio) }
                r.cues = try await Transcriber.transcribe(url: audio)
            } else {
                r.cues = try await Transcriber.transcribe(url: audioURL(r))
            }
            r.transcript = .done
        } catch {
            r.transcript = .failed
        }
        update(r)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(recordings) else { return }
        try? data.write(to: indexURL, options: .atomic)
    }
}

// MARK: - Recorder

enum RecorderError: LocalizedError {
    case micDenied, couldNotStart

    var errorDescription: String? {
        switch self {
        case .micDenied: return "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone."
        case .couldNotStart: return "The microphone couldn't start. Try again, or check that no other app is using it."
        }
    }
}

@Observable
final class ClassRecorder: NSObject {
    enum State { case idle, recording, paused }

    private(set) var state: State = .idle
    private(set) var time: TimeInterval = 0
    private(set) var level: Float = 0
    private(set) var inputName: String = ""

    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var plan = ClassPlan(week: 1)
    private var length: ClassLength = .sixty
    private var week = 1
    private var theme = ""
    private var startedAt = Date.now
    private var events: [ClassEvent] = []
    private var lastPhase: String?
    private var lastTrack: UUID?

    @MainActor
    func start(week: RotationWeek, plan: ClassPlan, length: ClassLength) async throws {
        guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.micDenied }

        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetooth])
        try session.setActive(true)

        let file = "class-\(Int(Date.now.timeIntervalSince1970)).m4a"
        let url = RecordingStore.directory.appending(path: file)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
        let r = try AVAudioRecorder(url: url, settings: settings)
        r.isMeteringEnabled = true
        guard r.record() else { throw RecorderError.couldNotStart }

        recorder = r
        self.plan = plan
        self.length = length
        self.week = week.number
        self.theme = week.theme
        startedAt = .now
        events = []
        lastPhase = nil
        lastTrack = nil
        time = 0
        inputName = session.currentRoute.inputs.first?.portName ?? "iPhone microphone"
        state = .recording

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.tick()
        }
        tick()
    }

    func pause() {
        guard state == .recording else { return }
        tick()
        recorder?.pause()
        state = .paused
        level = 0
    }

    func resume() {
        guard state == .paused, let recorder else { return }
        if recorder.record() { state = .recording }
    }

    func finish() -> RecordedClass? {
        guard let recorder else { return nil }
        if state == .recording { tick() }
        let duration = max(time, recorder.currentTime)
        let url = recorder.url
        recorder.stop()
        cleanup()
        guard duration > 5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordedClass(date: startedAt, week: week, theme: theme, length: length,
                             duration: duration, audioFile: url.lastPathComponent, events: events)
    }

    private func cleanup() {
        timer?.invalidate()
        timer = nil
        recorder = nil
        state = .idle
        level = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tick() {
        guard let recorder, recorder.isRecording else { return }
        let t = recorder.currentTime
        time = t

        recorder.updateMeters()
        let db = recorder.averagePower(forChannel: 0)
        level = max(0, min(1, (db + 50) / 50))

        if let phase = Content.phase(at: t / 60, length: length), phase.id != lastPhase {
            lastPhase = phase.id
            events.append(ClassEvent(kind: .phase, time: t, title: phase.name, detail: phase.bpm))
        }
        if let track = plan.track(at: t)?.track, track.id != lastTrack {
            lastTrack = track.id
            events.append(ClassEvent(kind: .track, time: t,
                                     title: track.title.isEmpty ? "Untitled" : track.title,
                                     detail: track.artist))
        }
    }
}

// MARK: - Transcription

enum TranscriptionError: Error { case unavailable }

private final class SegmentCollector {
    var finished = false
    var task: SFSpeechRecognitionTask?
    var recognizer: SFSpeechRecognizer?
    private var words: [Int: (start: TimeInterval, duration: TimeInterval, text: String)] = [:]

    func add(_ segments: [SFTranscriptionSegment]) {
        for s in segments where s.duration > 0 {
            words[Int((s.timestamp * 20).rounded())] = (s.timestamp, s.duration, s.substring)
        }
    }

    func cues() -> [Cue] {
        let sorted = words.values.sorted { $0.start < $1.start }
        var cues: [Cue] = []
        var start: TimeInterval = 0
        var end: TimeInterval = 0
        var text: [String] = []
        for w in sorted {
            if !text.isEmpty && (w.start - end > 1.2 || text.count >= 24) {
                cues.append(Cue(start: start, end: end, text: text.joined(separator: " ")))
                text = []
            }
            if text.isEmpty { start = w.start }
            text.append(w.text)
            end = w.start + w.duration
        }
        if !text.isEmpty {
            cues.append(Cue(start: start, end: end, text: text.joined(separator: " ")))
        }
        return cues
    }
}

enum Transcriber {
    static func authorize() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    static func extractAudio(from url: URL) async throws -> URL {
        let asset = AVURLAsset(url: url)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw TranscriptionError.unavailable
        }
        let out = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString + ".m4a")
        export.outputURL = out
        export.outputFileType = .m4a
        await export.export()
        guard export.status == .completed else {
            throw export.error ?? TranscriptionError.unavailable
        }
        return out
    }

    static func transcribe(url: URL) async throws -> [Cue] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), recognizer.isAvailable else {
            throw TranscriptionError.unavailable
        }
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = true
        request.addsPunctuation = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let collector = SegmentCollector()
        collector.recognizer = recognizer

        return try await withCheckedThrowingContinuation { continuation in
            collector.task = recognizer.recognitionTask(with: request) { result, error in
                if collector.finished { return }
                if let result {
                    collector.add(result.bestTranscription.segments)
                    if result.isFinal {
                        collector.finished = true
                        continuation.resume(returning: collector.cues())
                    }
                } else if let error {
                    collector.finished = true
                    let cues = collector.cues()
                    if cues.isEmpty {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: cues)
                    }
                }
            }
        }
    }
}

// MARK: - Playback

@Observable
final class ClassPlayer {
    private(set) var isPlaying = false
    private(set) var time: TimeInterval = 0
    private(set) var duration: TimeInterval = 0
    let player = AVPlayer()

    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var loadedURL: URL?

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    func load(_ url: URL) {
        guard loadedURL != url else { return }
        loadedURL = url
        let item = AVPlayerItem(url: url)
        player.replaceCurrentItem(with: item)
        time = 0
        duration = 0

        if timeObserver == nil {
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] t in
                guard let self, t.seconds.isFinite else { return }
                self.time = t.seconds
            }
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            self?.isPlaying = false
        }

        Task { @MainActor in
            if let d = try? await item.asset.load(.duration), d.seconds.isFinite {
                self.duration = d.seconds
            }
        }
    }

    func toggle() {
        isPlaying ? pause() : play()
    }

    func play() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if duration > 0 && time >= duration - 0.5 { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func seek(to t: TimeInterval) {
        let target = max(0, duration > 0 ? min(t, duration) : t)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        time = target
    }

    func skip(_ delta: TimeInterval) {
        seek(to: time + delta)
    }

    func stop() {
        player.pause()
        player.replaceCurrentItem(with: nil)
        loadedURL = nil
        isPlaying = false
    }
}
