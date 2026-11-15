import SwiftUI
import UIKit

struct TeachView: View {
    @Environment(PlanStore.self) private var store
    @Environment(RecordingStore.self) private var recordings
    @Environment(ClassRecorder.self) private var recorder
    @Environment(VideoRecorder.self) private var video
    @Environment(SpotifyController.self) private var spotify
    @AppStorage("playOnSpotify") private var playOnSpotify: Bool = true
    @AppStorage("recordMode") private var recordModeRaw: String = RecordMode.off.rawValue
    @AppStorage("videoQuality") private var qualityRaw: String = VideoQuality.hd.rawValue
    @AppStorage("videoOrientation") private var orientationRaw: String = VideoOrientation.landscape.rawValue
    @State private var recordError: String?
    @AppStorage("rotationStart") private var rotationStart: Double = 0
    @AppStorage("classLength") private var lengthRaw: Int = 60
    @AppStorage("teachWeek") private var pinnedWeek: Int = 0
    @AppStorage("timerStart") private var timerStart: Double = 0
    @AppStorage("timerAccumulated") private var accumulated: Double = 0
    @AppStorage("timerActive") private var active: Bool = false

    private var length: ClassLength { ClassLength(rawValue: lengthRaw) ?? .sixty }
    private var isRunning: Bool { timerStart > 0 }
    private var rotation: (week: Int, cycle: Int) {
        Rotation.current(start: Date(timeIntervalSince1970: rotationStart == 0 ? Date.now.timeIntervalSince1970 : rotationStart))
    }
    private var weekNumber: Int { (1...6).contains(pinnedWeek) ? pinnedWeek : rotation.week }
    private var week: RotationWeek { Content.weeks[weekNumber - 1] }

    private func elapsed(at date: Date) -> TimeInterval {
        accumulated + (isRunning ? date.timeIntervalSince1970 - timerStart : 0)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        LivePanel(week: week,
                                  plan: store.plan(for: week.number),
                                  length: length,
                                  elapsed: elapsed(at: context.date),
                                  active: active)
                    }
                    controls
                }
                .padding()
            }
            .background(Theme.ground)
            .navigationTitle("Teach")
        }
        .onChange(of: isRunning) { _, running in
            UIApplication.shared.isIdleTimerDisabled = running
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = isRunning }
        .alert("Recording problem", isPresented: Binding(get: { recordError != nil }, set: { if !$0 { recordError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(recordError ?? "")
        }
    }

    @ViewBuilder private var header: some View {
        Card {
            HStack {
                Eyebrow("Week \(week.number) of 6" + (weekNumber == rotation.week ? " · this week" : ""), color: Theme.warm)
                Spacer()
                Menu {
                    Button("This week (\(rotation.week))") { pinnedWeek = 0 }
                    Divider()
                    ForEach(Content.weeks) { w in
                        Button("Week \(w.number): \(w.theme)") { pinnedWeek = w.number }
                    }
                } label: {
                    Label("Change", systemImage: "chevron.up.chevron.down").font(.footnote)
                }
                .disabled(active)
            }
            Text(week.theme).font(Theme.display(.largeTitle)).fontWeight(.medium)
            Text(week.focus).font(.subheadline).foregroundStyle(Theme.inkSoft)
            if rotation.cycle > 1 && weekNumber == rotation.week {
                Text("Cycle \(rotation.cycle). Your regulars have met this peak before. Tell them.")
                    .font(.footnote)
                    .foregroundStyle(Theme.cool)
            }
            Picker("Length", selection: $lengthRaw) {
                ForEach(ClassLength.allCases) { Text($0.label).tag($0.rawValue) }
            }
            .pickerStyle(.segmented)
            .disabled(active)
        }
    }

    private var recordMode: RecordMode { RecordMode(rawValue: recordModeRaw) ?? .off }

    @ViewBuilder private var controls: some View {
        if !active {
            Card {
                HStack {
                    Label("Record", systemImage: "record.circle")
                    Spacer()
                }
                Picker("Record", selection: $recordModeRaw) {
                    ForEach(RecordMode.allCases) { Text($0.rawValue).tag($0.rawValue) }
                }
                .pickerStyle(.segmented)
                switch recordMode {
                case .off:
                    EmptyView()
                case .voice:
                    Text("Records your cues only. Music is logged by track, never recorded. A clip-on mic or AirPods keeps the speakers out of the recording.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                case .video:
                    VideoSetupCard(qualityRaw: $qualityRaw, orientationRaw: $orientationRaw, length: length)
                }
            }
            .task(id: "\(recordModeRaw)|\(qualityRaw)|\(orientationRaw)") {
                if recordMode == .video {
                    await video.prepare(quality: VideoQuality(rawValue: qualityRaw) ?? .hd,
                                        orientation: VideoOrientation(rawValue: orientationRaw) ?? .landscape)
                } else {
                    video.shutdown()
                }
            }

            SpotifyClassCard(plan: store.plan(for: week.number))

            Button {
                startClass()
            } label: {
                Label(startLabel, systemImage: recordMode == .off ? "play.fill" : "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(recordMode == .video && !video.isConfigured)
        } else {
            if recorder.state != .idle {
                RecordingBadge()
            }
            if video.isRecording {
                VideoRecordingBadge()
            }
            if spotify.isClassActive {
                SpotifyNowPlayingBadge()
            }
            HStack(spacing: 12) {
                if isRunning {
                    Button {
                        accumulated += Date.now.timeIntervalSince1970 - timerStart
                        timerStart = 0
                        recorder.pause()
                        video.pause()
                        spotify.pauseClass()
                    } label: {
                        Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        timerStart = Date.now.timeIntervalSince1970
                        recorder.resume()
                        video.resume()
                        spotify.resumeClass()
                    } label: {
                        Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                }
                Button(role: .destructive) {
                    endClass()
                } label: {
                    Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .controlSize(.large)
        }
    }

    private var startLabel: String {
        switch recordMode {
        case .off: return "Start class"
        case .voice: return "Start class and record voice"
        case .video: return "Start class and record video"
        }
    }

    private func beginTimer() {
        accumulated = 0
        timerStart = Date.now.timeIntervalSince1970
        active = true
        startMusic()
    }

    private func startMusic() {
        let plan = store.plan(for: week.number)
        guard playOnSpotify, spotify.isConnected, plan.tracks.contains(where: { $0.spotifyURI != nil }) else { return }
        let currentLength = length
        Task { @MainActor in
            await spotify.startClass(plan: plan, length: currentLength)
        }
    }

    private func startClass() {
        let plan = store.plan(for: week.number)
        let currentWeek = week
        let currentLength = length
        switch recordMode {
        case .off:
            beginTimer()
        case .voice:
            Task { @MainActor in
                do {
                    try await recorder.start(week: currentWeek, plan: plan, length: currentLength)
                    beginTimer()
                } catch {
                    recordError = error.localizedDescription
                }
            }
        case .video:
            guard video.isConfigured else {
                recordError = "The camera isn't ready yet."
                return
            }
            video.start(week: currentWeek, plan: plan, length: currentLength)
            beginTimer()
        }
    }

    private func endClass() {
        spotify.endClass()
        active = false
        timerStart = 0
        accumulated = 0
        if recorder.state != .idle, let rec = recorder.finish() {
            recordings.add(rec)
            Task { @MainActor in
                await recordings.transcribe(rec.id)
            }
        }
        if video.isRecording {
            Task { @MainActor in
                if let rec = await video.finish() {
                    recordings.add(rec)
                    await recordings.transcribe(rec.id)
                } else {
                    recordError = "The video didn't save. Check free space and try a shorter test."
                }
            }
        }
    }
}

private struct RecordingBadge: View {
    @Environment(ClassRecorder.self) private var recorder

    var body: some View {
        let live = recorder.state == .recording
        HStack(spacing: 10) {
            Circle()
                .fill(live ? Color.red : Theme.inkSoft)
                .frame(width: 10, height: 10)
            Text(live ? "REC" : "PAUSED")
                .font(Theme.eyebrow)
            Text(recorder.inputName)
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
                .lineLimit(1)
            Spacer()
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.ink.opacity(0.1)).frame(width: 60, height: 6)
                Capsule().fill(Theme.cool).frame(width: 60 * CGFloat(recorder.level), height: 6)
            }
            .animation(.linear(duration: 0.2), value: recorder.level)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct LivePanel: View {
    let week: RotationWeek
    let plan: ClassPlan
    let length: ClassLength
    let elapsed: TimeInterval
    let active: Bool

    private var minutes: Double { elapsed / 60 }
    private var phase: Phase? { active ? Content.phase(at: minutes, length: length) : nil }
    private var total: TimeInterval { TimeInterval(length.minutes * 60) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card {
                ArcChart(length: length, nowMinute: active ? min(minutes, Double(length.minutes)) : nil)
                    .frame(height: 170)
                if active {
                    HStack(alignment: .firstTextBaseline) {
                        Text(Fmt.clock(elapsed))
                            .font(.system(size: 44, weight: .medium, design: .monospaced))
                            .contentTransition(.numericText())
                        Text("/ \(Fmt.clock(total))")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            if active {
                if let phase { phaseCard(phase) } else { finished }
            } else {
                preview
            }
        }
        .sensoryFeedback(.impact(weight: .medium), trigger: phase?.id)
    }

    @ViewBuilder private func phaseCard(_ phase: Phase) -> some View {
        let remaining = phase.end(length) * 60 - elapsed
        let peak = Content.phases.first { $0.isPeak }!
        let next = Content.phases.first { $0.start(length) >= phase.end(length) }
        Card {
            HStack {
                Eyebrow("Now", color: phase.isPeak ? Theme.plum : Theme.warm)
                Spacer()
                Text(phase.bpm).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.warm)
            }
            Text(phase.name).font(Theme.display(.largeTitle)).fontWeight(.medium)
            Text("\(Fmt.clock(remaining)) left in this phase")
                .font(.system(.subheadline, design: .monospaced))
            let note = plan.phaseNotes[phase.id] ?? ""
            if !note.isEmpty {
                Text(note).font(.body)
            } else if phase.isPeak {
                Text(plan.peakShape.isEmpty ? week.peak : plan.peakShape).font(.body)
            }
        }
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(phase.isPeak ? Theme.plum : Theme.warm).frame(width: 3).padding(.vertical, 12)
        }

        Card {
            if minutes < peak.start(length) {
                row("Peak in", Fmt.clock(peak.start(length) * 60 - elapsed))
            } else if phase.isPeak {
                row("Peak", "happening now")
            }
            if let next {
                row("Next", "\(next.name) at \(Fmt.minute(next.start(length))):00")
            }
            if let playing = plan.track(at: elapsed) {
                Divider()
                Eyebrow("Planned track")
                Text(playing.track.title.isEmpty ? "Untitled" : playing.track.title).font(.headline)
                HStack {
                    if !playing.track.artist.isEmpty { Text(playing.track.artist) }
                    Spacer()
                    Text("\(Fmt.clock(playing.remaining)) left").font(.system(.footnote, design: .monospaced))
                }
                .font(.subheadline)
                .foregroundStyle(Theme.inkSoft)
            } else if !plan.tracks.isEmpty {
                Divider()
                Text("Playlist has ended.").font(.subheadline).foregroundStyle(Theme.plum)
            }
            if phase.id == "savasana" && !plan.oneThing.isEmpty {
                Divider()
                Eyebrow("One thing to say")
                Text(plan.oneThing)
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.inkSoft)
            Spacer()
            Text(value).font(.system(.body, design: .monospaced))
        }
    }

    private var finished: some View {
        Card {
            Text("Class complete").font(Theme.display(.title)).fontWeight(.medium)
            Text("\(Fmt.clock(elapsed - total)) over").font(.system(.subheadline, design: .monospaced)).foregroundStyle(Theme.inkSoft)
        }
    }

    private var preview: some View {
        Card {
            Eyebrow("Peak shape", color: Theme.warm)
            Text(plan.peakShape.isEmpty ? week.peak : plan.peakShape).font(.body)
            Divider()
            HStack {
                Label("\(plan.filledFields)/\(ClassPlan.totalFields) plan fields", systemImage: "square.and.pencil")
                Spacer()
                Label(plan.tracks.isEmpty ? "No playlist" : "\(plan.tracks.count) tracks · \(Fmt.clock(TimeInterval(plan.totalSeconds)))", systemImage: "music.note.list")
            }
            .font(.footnote)
            .foregroundStyle(Theme.inkSoft)
            if !plan.warnings.isEmpty {
                Label("\(plan.warnings.count) playlist issue\(plan.warnings.count == 1 ? "" : "s") to check in Weeks", systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(Theme.plum)
            }
        }
    }
}
