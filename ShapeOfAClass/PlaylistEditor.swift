import SwiftUI

struct PlaylistEditor: View {
    @Environment(PlanStore.self) private var store
    let week: RotationWeek
    @State private var plan: ClassPlan
    @State private var editing: Track?
    @State private var showImport = false

    init(week: RotationWeek, initial: ClassPlan) {
        self.week = week
        _plan = State(initialValue: initial)
    }

    var body: some View {
        List {
            Section {
                summary
            }
            if !plan.warnings.isEmpty {
                Section("Check") {
                    ForEach(plan.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle")
                            .font(.footnote)
                            .foregroundStyle(Theme.plum)
                    }
                }
            }
            ForEach(Content.phases) { phase in
                Section {
                    ForEach(plan.tracks(in: phase)) { track in
                        Button { editing = track } label: { TrackRow(track: track) }
                            .tint(Theme.ink)
                    }
                    .onDelete { delete(in: phase, at: $0) }
                    .onMove { move(in: phase, from: $0, to: $1) }
                    Button {
                        let t = Track(phaseID: phase.id)
                        plan.tracks.append(t)
                        editing = t
                    } label: {
                        Label("Add track", systemImage: "plus")
                    }
                } header: {
                    PhaseHeader(alignment: plan.alignment.first { $0.id == phase.id }!)
                } footer: {
                    Text(phase.music)
                }
            }
        }
        .navigationTitle("\(week.theme) playlist")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showImport = true
                } label: {
                    Label("Import from Spotify", systemImage: "square.and.arrow.down")
                }
                EditButton()
            }
        }
        .sheet(isPresented: $showImport) {
            SpotifyImportSheet(length: plan.length, replacing: !plan.tracks.isEmpty) { imported in
                plan.tracks = imported
            }
        }
        .sheet(item: $editing) { track in
            TrackEditor(track: track) { updated in
                if let i = plan.tracks.firstIndex(where: { $0.id == updated.id }) {
                    plan.tracks[i] = updated
                }
            } onDelete: {
                plan.tracks.removeAll { $0.id == track.id }
            }
        }
        .onChange(of: plan) { _, newValue in store.save(newValue) }
    }

    private var summary: some View {
        let total = plan.totalSeconds
        let target = plan.targetSeconds
        let ok = total >= target
        return VStack(alignment: .leading, spacing: 10) {
            Picker("Length", selection: $plan.length) {
                ForEach(ClassLength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack(alignment: .firstTextBaseline) {
                Text(Fmt.clock(TimeInterval(total)))
                    .font(.system(size: 34, weight: .medium, design: .monospaced))
                Text("of \(Fmt.clock(TimeInterval(target))) target")
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(Theme.inkSoft)
                Spacer()
                Image(systemName: ok ? "checkmark.circle.fill" : "clock")
                    .foregroundStyle(ok ? Theme.cool : Theme.warm)
            }
            ProgressView(value: min(Double(total), Double(target)), total: Double(target))
                .tint(ok ? Theme.cool : Theme.warm)
            Text("Class length plus five minutes, so savasana never ends in silence.")
                .font(.caption)
                .foregroundStyle(Theme.inkSoft)
        }
        .padding(.vertical, 4)
    }

    private func delete(in phase: Phase, at offsets: IndexSet) {
        let sub = plan.tracks(in: phase)
        let ids = Set(offsets.map { sub[$0].id })
        plan.tracks.removeAll { ids.contains($0.id) }
    }

    private func move(in phase: Phase, from: IndexSet, to: Int) {
        var sub = plan.tracks(in: phase)
        sub.move(fromOffsets: from, toOffset: to)
        var iterator = sub.makeIterator()
        plan.tracks = plan.tracks.map { $0.phaseID == phase.id ? (iterator.next() ?? $0) : $0 }
    }
}

private struct PhaseHeader: View {
    let alignment: PhaseAlignment

    var body: some View {
        let fill = alignment.neededSeconds == 0 ? 0 : Double(alignment.plannedSeconds) / Double(alignment.neededSeconds)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(alignment.phase.name)
                Spacer()
                Text("\(Fmt.clock(TimeInterval(alignment.plannedSeconds))) / \(Fmt.clock(TimeInterval(alignment.neededSeconds)))")
                    .font(.system(.caption2, design: .monospaced))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.ink.opacity(0.08))
                    Capsule().fill(fill >= 0.95 ? Theme.cool : Theme.warm)
                        .frame(width: geo.size.width * min(fill, 1))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct TrackRow: View {
    let track: Track
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title.isEmpty ? "Untitled" : track.title)
                if !track.artist.isEmpty {
                    Text(track.artist).font(.footnote).foregroundStyle(Theme.inkSoft)
                }
            }
            Spacer()
            if track.spotifyURI != nil {
                Image(systemName: "dot.radiowaves.right")
                    .font(.caption2)
                    .foregroundStyle(Theme.cool)
            }
            Text(Fmt.clock(TimeInterval(track.seconds)))
                .font(.system(.footnote, design: .monospaced))
                .foregroundStyle(Theme.inkSoft)
        }
    }
}

private struct TrackEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var track: Track
    let onSave: (Track) -> Void
    let onDelete: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $track.title)
                    TextField("Artist", text: $track.artist)
                }
                Section("Length") {
                    HStack {
                        Picker("Minutes", selection: minutes) {
                            ForEach(0..<31) { Text("\($0) min").tag($0) }
                        }
                        .pickerStyle(.wheel)
                        Picker("Seconds", selection: seconds) {
                            ForEach(0..<60) { Text(String(format: "%02d sec", $0)).tag($0) }
                        }
                        .pickerStyle(.wheel)
                    }
                    .frame(height: 130)
                }
                Section("Phase") {
                    Picker("Phase", selection: $track.phaseID) {
                        ForEach(Content.phases) { Text($0.name).tag($0.id) }
                    }
                }
                Section {
                    Button("Delete track", role: .destructive) {
                        onDelete()
                        dismiss()
                    }
                }
            }
            .navigationTitle(track.title.isEmpty ? "Track" : track.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        onSave(track)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.large])
    }

    private var minutes: Binding<Int> {
        Binding(get: { track.seconds / 60 }, set: { track.seconds = $0 * 60 + track.seconds % 60 })
    }
    private var seconds: Binding<Int> {
        Binding(get: { track.seconds % 60 }, set: { track.seconds = (track.seconds / 60) * 60 + $0 })
    }
}
