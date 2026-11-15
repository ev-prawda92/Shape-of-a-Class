import SwiftUI
import AVFoundation
import Observation

enum RecordMode: String, CaseIterable, Identifiable {
    case off = "Off"
    case voice = "Voice"
    case video = "Video"
    var id: String { rawValue }
}

enum VideoQuality: String, CaseIterable, Identifiable {
    case uhd = "4K"
    case hd = "1080p"
    var id: String { rawValue }
    var megabytesPerMinute: Double { self == .uhd ? 350 : 110 }
}

enum VideoOrientation: String, CaseIterable, Identifiable {
    case landscape = "Landscape"
    case portrait = "Portrait"
    var id: String { rawValue }
    var angle: CGFloat { self == .landscape ? 0 : 90 }
    var aspect: CGFloat { self == .landscape ? 16.0 / 9.0 : 9.0 / 16.0 }
}

enum Storage {
    static func freeBytes() -> Int64 {
        let values = try? URL.documentsDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? 0
    }

    static func gigabytes(_ bytes: Double) -> String {
        String(format: "%.1f GB", bytes / 1_000_000_000)
    }
}

@Observable
final class VideoRecorder: NSObject, AVCaptureFileOutputRecordingDelegate {
    private(set) var isConfigured = false
    private(set) var hasCamera = true
    private(set) var authorized = true
    private(set) var supports4K = false
    private(set) var isRecording = false
    private(set) var isPaused = false
    private(set) var inputName = ""
    private(set) var isBuiltInMic = true
    private(set) var level: Float = 0
    private(set) var thermal: ProcessInfo.ThermalState = ProcessInfo.processInfo.thermalState
    private(set) var activeQuality: VideoQuality = .hd
    private(set) var orientation: VideoOrientation = .landscape

    let session = AVCaptureSession()
    private let output = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "shapeofaclass.capture")

    private var meterTimer: Timer?
    private var eventTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var finishContinuation: CheckedContinuation<URL?, Never>?

    private var plan = ClassPlan(week: 1)
    private var length: ClassLength = .sixty
    private var week = 1
    private var theme = ""
    private var startDate = Date.now
    private var classDate = Date.now
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?
    private var events: [ClassEvent] = []
    private var lastPhase: String?
    private var lastTrack: UUID?

    override init() {
        super.init()
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refreshRoute()
        })
        observers.append(center.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.thermal = ProcessInfo.processInfo.thermalState
        })
    }

    // MARK: Setup

    @MainActor
    func prepare(quality: VideoQuality, orientation: VideoOrientation) async {
        let camOK = await AVCaptureDevice.requestAccess(for: .video)
        let micOK = await AVAudioApplication.requestRecordPermission()
        guard camOK && micOK else {
            authorized = false
            return
        }
        authorized = true
        self.orientation = orientation

        let audio = AVAudioSession.sharedInstance()
        try? audio.setCategory(.playAndRecord, mode: .videoRecording, options: [.mixWithOthers, .allowBluetooth, .defaultToSpeaker])
        try? audio.setActive(true)

        let session = self.session
        let output = self.output
        let result: (camera: Bool, can4K: Bool, running: Bool) = await withCheckedContinuation { continuation in
            queue.async {
                session.beginConfiguration()
                session.automaticallyConfiguresApplicationAudioSession = false
                session.usesApplicationAudioSession = true

                var camera = session.inputs.contains { ($0 as? AVCaptureDeviceInput)?.device.hasMediaType(.video) == true }
                if session.inputs.isEmpty {
                    if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                       let input = try? AVCaptureDeviceInput(device: device),
                       session.canAddInput(input) {
                        session.addInput(input)
                        camera = true
                    }
                    if let mic = AVCaptureDevice.default(for: .audio),
                       let input = try? AVCaptureDeviceInput(device: mic),
                       session.canAddInput(input) {
                        session.addInput(input)
                    }
                    if session.canAddOutput(output) {
                        session.addOutput(output)
                    }
                }

                let can4K = session.canSetSessionPreset(.hd4K3840x2160)
                let preset: AVCaptureSession.Preset = (quality == .uhd && can4K) ? .hd4K3840x2160 : .hd1920x1080
                if session.canSetSessionPreset(preset) {
                    session.sessionPreset = preset
                }
                if let connection = output.connection(with: .video) {
                    if connection.isVideoRotationAngleSupported(orientation.angle) {
                        connection.videoRotationAngle = orientation.angle
                    }
                    if connection.isVideoStabilizationSupported {
                        connection.preferredVideoStabilizationMode = .auto
                    }
                }
                session.commitConfiguration()

                if camera && !session.isRunning {
                    session.startRunning()
                }
                continuation.resume(returning: (camera, can4K, session.isRunning))
            }
        }

        hasCamera = result.camera
        supports4K = result.can4K
        activeQuality = (quality == .uhd && result.can4K) ? .uhd : .hd
        isConfigured = result.running
        refreshRoute()
        startMeter()
    }

    func shutdown() {
        guard !isRecording else { return }
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
        isConfigured = false
        let session = self.session
        queue.async {
            if session.isRunning { session.stopRunning() }
        }
    }

    private func refreshRoute() {
        let input = AVAudioSession.sharedInstance().currentRoute.inputs.first
        inputName = input?.portName ?? "No microphone"
        isBuiltInMic = input == nil || input?.portType == .builtInMic
    }

    private func startMeter() {
        meterTimer?.invalidate()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let db = self.output.connection(with: .audio)?.audioChannels.first?.averagePowerLevel ?? -60
            self.level = max(0, min(1, (db + 50) / 50))
        }
    }

    // MARK: Recording

    @MainActor
    func start(week: RotationWeek, plan: ClassPlan, length: ClassLength) {
        guard isConfigured, !isRecording else { return }
        self.plan = plan
        self.length = length
        self.week = week.number
        self.theme = week.theme
        events = []
        lastPhase = nil
        lastTrack = nil
        pausedTotal = 0
        pauseStart = nil
        startDate = .now
        classDate = .now
        isPaused = false
        isRecording = true

        let url = RecordingStore.directory.appending(path: "class-\(Int(Date.now.timeIntervalSince1970)).mov")
        let output = self.output
        queue.async {
            output.startRecording(to: url, recordingDelegate: self)
        }

        eventTimer?.invalidate()
        eventTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.tick()
        }
    }

    func pause() {
        guard isRecording, !isPaused else { return }
        tick()
        pauseStart = .now
        isPaused = true
    }

    func resume() {
        guard isRecording, isPaused, let pauseStart else { return }
        pausedTotal += Date.now.timeIntervalSince(pauseStart)
        self.pauseStart = nil
        isPaused = false
    }

    @MainActor
    func finish() async -> RecordedClass? {
        guard isRecording else { return nil }
        if !isPaused { tick() }
        eventTimer?.invalidate()
        eventTimer = nil

        let output = self.output
        let url: URL? = await withCheckedContinuation { continuation in
            finishContinuation = continuation
            queue.async {
                if output.isRecording {
                    output.stopRecording()
                } else {
                    DispatchQueue.main.async {
                        self.finishContinuation?.resume(returning: nil)
                        self.finishContinuation = nil
                    }
                }
            }
        }
        isRecording = false
        isPaused = false

        guard let url else { return nil }
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? Date.now.timeIntervalSince(startDate)
        guard seconds.isFinite, seconds > 5 else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return RecordedClass(date: classDate, week: week, theme: theme, length: length,
                             duration: seconds, audioFile: url.lastPathComponent,
                             events: events, video: true)
    }

    private func tick() {
        guard isRecording, !isPaused else { return }
        let mediaTime = Date.now.timeIntervalSince(startDate)
        let classTime = mediaTime - pausedTotal

        if let phase = Content.phase(at: classTime / 60, length: length), phase.id != lastPhase {
            lastPhase = phase.id
            events.append(ClassEvent(kind: .phase, time: max(0, mediaTime), title: phase.name, detail: phase.bpm))
        }
        if let track = plan.track(at: classTime)?.track, track.id != lastTrack {
            lastTrack = track.id
            events.append(ClassEvent(kind: .track, time: max(0, mediaTime),
                                     title: track.title.isEmpty ? "Untitled" : track.title,
                                     detail: track.artist))
        }
    }

    // MARK: AVCaptureFileOutputRecordingDelegate

    func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
        DispatchQueue.main.async {
            self.startDate = .now
        }
    }

    func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo outputFileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
        var success = error == nil
        if let error = error as NSError?, let finished = error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool {
            success = finished
        }
        DispatchQueue.main.async {
            self.finishContinuation?.resume(returning: success ? outputFileURL : nil)
            self.finishContinuation = nil
        }
    }
}

// MARK: - Views

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let angle: CGFloat

    final class PreviewView: UIView {
        var angle: CGFloat = 0
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

        override func layoutSubviews() {
            super.layoutSubviews()
            if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
        }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        view.angle = angle
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.angle = angle
        view.setNeedsLayout()
    }
}

struct PlayerLayerView: UIViewRepresentable {
    let player: AVPlayer

    final class LayerView: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> LayerView {
        let view = LayerView()
        view.backgroundColor = .black
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        return view
    }

    func updateUIView(_ view: LayerView, context: Context) {
        view.playerLayer.player = player
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(Theme.ink.opacity(0.1)).frame(width: 70, height: 6)
            Capsule().fill(Theme.cool).frame(width: 70 * CGFloat(level), height: 6)
        }
        .animation(.linear(duration: 0.2), value: level)
    }
}

struct VideoSetupCard: View {
    @Environment(VideoRecorder.self) private var video
    @Binding var qualityRaw: String
    @Binding var orientationRaw: String
    let length: ClassLength

    private var quality: VideoQuality { VideoQuality(rawValue: qualityRaw) ?? .hd }
    private var orientation: VideoOrientation { VideoOrientation(rawValue: orientationRaw) ?? .landscape }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !video.authorized {
                Label("Camera or microphone access is off. Turn both on in Settings > Privacy & Security for Shape of a Class.", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.plum)
            } else if !video.hasCamera {
                Label("No camera available here. The simulator has no camera, so test video on your iPhone.", systemImage: "video.slash")
                    .font(.footnote)
                    .foregroundStyle(Theme.plum)
            } else {
                ZStack {
                    Color.black
                    if video.isConfigured {
                        CameraPreview(session: video.session, angle: orientation.angle)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .aspectRatio(orientation.aspect, contentMode: .fit)
                .frame(maxHeight: 320)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                Text(orientation == .landscape
                     ? "Turn the phone sideways on a tripod and frame your whole mat. Check the preview matches."
                     : "Stand the phone upright on a tripod and frame your whole mat.")
                    .font(.caption)
                    .foregroundStyle(Theme.inkSoft)
            }

            Picker("Quality", selection: $qualityRaw) {
                ForEach(VideoQuality.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            Picker("Orientation", selection: $orientationRaw) {
                ForEach(VideoOrientation.allCases) { Text($0.rawValue).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)

            if video.isConfigured && quality == .uhd && !video.supports4K {
                Text("This device can't record 4K here, so it will record 1080p.")
                    .font(.caption)
                    .foregroundStyle(Theme.warm)
            }

            Divider()

            HStack(spacing: 10) {
                Image(systemName: video.isBuiltInMic ? "mic.badge.xmark" : "mic.fill")
                    .foregroundStyle(video.isBuiltInMic ? Theme.plum : Theme.cool)
                VStack(alignment: .leading, spacing: 2) {
                    Text(video.inputName).font(.subheadline)
                    Text("Speak to check the level")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
                Spacer()
                LevelMeter(level: video.level)
            }
            if video.isBuiltInMic {
                Text("You're on the phone's built-in mic. Across the room it will pick up the speakers and echo. Connect a wireless clip-on mic for clean cues with no music.")
                    .font(.caption)
                    .foregroundStyle(Theme.plum)
            }

            let needed = Double(length.minutes + 10) * video.activeQuality.megabytesPerMinute * 1_000_000
            let free = Double(Storage.freeBytes())
            HStack {
                Image(systemName: "internaldrive")
                Text("About \(Storage.gigabytes(needed)) needed · \(Storage.gigabytes(free)) free")
            }
            .font(.caption)
            .foregroundStyle(free < needed ? Theme.plum : Theme.inkSoft)
            if free < needed {
                Text("Not enough space for a full class at this quality. Free up space or switch to 1080p.")
                    .font(.caption)
                    .foregroundStyle(Theme.plum)
            }

            Text("Keep the phone plugged in, and keep the app open while recording.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

struct VideoRecordingBadge: View {
    @Environment(VideoRecorder.self) private var video

    var body: some View {
        let live = video.isRecording && !video.isPaused
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Circle()
                    .fill(live ? Color.red : Theme.inkSoft)
                    .frame(width: 10, height: 10)
                Text(live ? "REC \(video.activeQuality.rawValue)" : "PAUSED · CAMERA STILL ROLLING")
                    .font(Theme.eyebrow)
                Spacer()
                LevelMeter(level: video.level)
            }
            HStack(spacing: 12) {
                CameraPreview(session: video.session, angle: video.orientation.angle)
                    .aspectRatio(video.orientation.aspect, contentMode: .fit)
                    .frame(height: 90)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                VStack(alignment: .leading, spacing: 4) {
                    Label(video.inputName, systemImage: video.isBuiltInMic ? "mic.badge.xmark" : "mic.fill")
                        .font(.caption)
                        .lineLimit(1)
                    if video.thermal == .serious || video.thermal == .critical {
                        Label("Phone is hot. Move it out of the sun or remove the case.", systemImage: "thermometer.high")
                            .font(.caption)
                            .foregroundStyle(Theme.plum)
                    }
                    if video.isPaused {
                        Text("Video keeps recording while paused. The timeline stays in sync.")
                            .font(.caption2)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
