import SwiftUI

struct RecordingsView: View {
    @Environment(RecordingStore.self) private var store

    var body: some View {
        NavigationStack {
            Group {
                if store.recordings.isEmpty {
                    ContentUnavailableView {
                        Label("No recorded classes", systemImage: "waveform")
                    } description: {
                        Text("On the Teach screen, set Record to Voice or Video before you start class. Your voice is recorded. The music is logged by track, never recorded.")
                    }
                } else {
                    List {
                        ForEach(store.recordings) { rec in
                            NavigationLink(value: rec.id) {
                                VStack(alignment: .leading, spacing: 4) {
                                    HStack {
                                        Image(systemName: rec.isVideo ? "video.fill" : "waveform")
                                            .font(.footnote)
                                            .foregroundStyle(Theme.warm)
                                        Text(rec.theme).font(Theme.display(.title3)).fontWeight(.medium)
                                        Spacer()
                                        Text(Fmt.clock(rec.duration))
                                            .font(.system(.footnote, design: .monospaced))
                                            .foregroundStyle(Theme.inkSoft)
                                    }
                                    Text("Week \(rec.week) · \(rec.length.label) · \(rec.date.formatted(date: .abbreviated, time: .shortened))")
                                        .font(.footnote)
                                        .foregroundStyle(Theme.inkSoft)
                                    TranscriptBadge(status: rec.transcript, count: rec.cues.count)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete { offsets in
                            let items = offsets.map { store.recordings[$0] }
                            items.forEach { store.delete($0) }
                        }
                    }
                }
            }
            .navigationTitle("Classes")
            .navigationDestination(for: UUID.self) { RecordingDetailView(id: $0) }
        }
    }
}

private struct TranscriptBadge: View {
    let status: TranscriptStatus
    let count: Int

    var body: some View {
        switch status {
        case .pending, .working:
            Label("Transcribing cues…", systemImage: "text.bubble").font(.caption2).foregroundStyle(Theme.warm)
        case .done:
            Label("\(count) cues", systemImage: "text.bubble").font(.caption2).foregroundStyle(Theme.cool)
        case .failed:
            Label("Transcription failed", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(Theme.plum)
        case .denied:
            Label("Speech recognition is off", systemImage: "exclamationmark.triangle").font(.caption2).foregroundStyle(Theme.plum)
        }
    }
}

struct RecordingDetailView: View {
    @Environment(RecordingStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let id: UUID
    @State private var player = ClassPlayer()
    @State private var confirmDelete = false

    var body: some View {
        if let rec = store.recording(id) {
            content(rec)
        } else {
            ContentUnavailableView("Recording removed", systemImage: "trash")
        }
    }

    @ViewBuilder
    private func content(_ rec: RecordedClass) -> some View {
        let t = player.time
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Card {
                    Eyebrow("Week \(rec.week) · \(rec.length.label)", color: Theme.warm)
                    Text(rec.theme).font(Theme.display(.largeTitle)).fontWeight(.medium)
                    Text(rec.date.formatted(date: .complete, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(Theme.inkSoft)
                }

                if rec.isVideo {
                    PlayerLayerView(player: player.player)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .onTapGesture { player.toggle() }
                }

                Card {
                    ArcChart(length: rec.length, nowMinute: min(t / 60, Double(rec.length.minutes)))
                        .frame(height: 150)
                    Slider(value: Binding(get: { player.time }, set: { player.seek(to: $0) }),
                           in: 0...max(player.duration, 1))
                    HStack {
                        Text(Fmt.clock(t))
                        Spacer()
                        Text("-" + Fmt.clock(max(0, player.duration - t)))
                    }
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.inkSoft)
                    HStack(spacing: 44) {
                        Button { player.skip(-15) } label: { Image(systemName: "gobackward.15") }
                        Button { player.toggle() } label: {
                            Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                                .font(.system(size: 58))
                        }
                        Button { player.skip(15) } label: { Image(systemName: "goforward.15") }
                    }
                    .font(.title2)
                    .frame(maxWidth: .infinity)
                }

                Card {
                    Eyebrow("Now")
                    if let phase = rec.event(.phase, at: t) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(phase.title).font(Theme.display(.title)).fontWeight(.medium)
                            Spacer()
                            Text(phase.detail).font(.system(.footnote, design: .monospaced)).foregroundStyle(Theme.warm)
                        }
                    }
                    if let track = rec.event(.track, at: t) {
                        Label {
                            Text(track.title + (track.detail.isEmpty ? "" : " — \(track.detail)"))
                        } icon: {
                            Image(systemName: "music.note")
                        }
                        .font(.subheadline)
                        Text("Play this track from your own music app.")
                            .font(.caption)
                            .foregroundStyle(Theme.inkSoft)
                    }
                }

                cueSection(rec, time: t)

                if !rec.events.isEmpty {
                    Card {
                        Eyebrow("Timeline")
                        ForEach(rec.events) { e in
                            Button {
                                player.seek(to: e.time)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 12) {
                                    Text(Fmt.clock(e.time))
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundStyle(Theme.inkSoft)
                                        .frame(width: 48, alignment: .leading)
                                    Image(systemName: e.kind == .phase ? "circle.fill" : "music.note")
                                        .font(.caption2)
                                        .foregroundStyle(e.kind == .phase ? Theme.warm : Theme.cool)
                                    Text(e.title).font(e.kind == .phase ? .headline : .subheadline)
                                    Spacer()
                                }
                            }
                            .tint(Theme.ink)
                        }
                    }
                }
            }
            .padding()
        }
        .background(Theme.ground)
        .navigationTitle(rec.theme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Menu {
                ShareLink(item: rec.cueSheet) {
                    Label("Share cue sheet", systemImage: "square.and.arrow.up")
                }
                if rec.transcript == .failed || rec.transcript == .done {
                    Button {
                        Task { await store.transcribe(rec.id) }
                    } label: {
                        Label("Transcribe again", systemImage: "arrow.clockwise")
                    }
                }
                Button(role: .destructive) {
                    confirmDelete = true
                } label: {
                    Label("Delete recording", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .confirmationDialog("Delete this recording?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                player.stop()
                store.delete(rec)
                dismiss()
            }
        }
        .onAppear { player.load(store.audioURL(rec)) }
        .onDisappear { player.pause() }
    }

    @ViewBuilder
    private func cueSection(_ rec: RecordedClass, time t: TimeInterval) -> some View {
        Card {
            Eyebrow("Your cues", color: Theme.cool)
            switch rec.transcript {
            case .pending, .working:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Transcribing on this phone. A full class can take a few minutes.")
                        .font(.subheadline)
                }
            case .denied:
                Text("Speech recognition is turned off. Turn it on in Settings > Privacy & Security > Speech Recognition, then choose Transcribe again.")
                    .font(.subheadline)
            case .failed:
                Text("Transcription didn't finish. Your recording is safe. Try Transcribe again from the menu.")
                    .font(.subheadline)
            case .done where rec.cues.isEmpty:
                Text("No speech was detected in this recording.")
                    .font(.subheadline)
            case .done:
                let active = rec.cueID(at: t)
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(rec.cues) { cue in
                        Button {
                            player.seek(to: cue.start)
                            if !player.isPlaying { player.play() }
                        } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(Fmt.clock(cue.start))
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(Theme.inkSoft)
                                    .frame(width: 48, alignment: .leading)
                                Text(cue.text)
                                    .font(.subheadline)
                                    .multilineTextAlignment(.leading)
                                    .foregroundStyle(cue.id == active ? Theme.ink : Theme.ink.opacity(0.55))
                                    .fontWeight(cue.id == active ? .semibold : .regular)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }
}
