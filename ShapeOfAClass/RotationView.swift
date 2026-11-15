import SwiftUI

struct RotationView: View {
    @Environment(PlanStore.self) private var store
    @AppStorage("rotationStart") private var rotationStart: Double = 0

    var body: some View {
        let current = Rotation.current(start: Date(timeIntervalSince1970: rotationStart == 0 ? Date.now.timeIntervalSince1970 : rotationStart))
        NavigationStack {
            List {
                Section {
                    Text(Content.whyRotation).font(.callout).foregroundStyle(Theme.ink.opacity(0.8))
                }
                Section("Cycle \(current.cycle)") {
                    ForEach(Content.weeks) { week in
                        let plan = store.plan(for: week.number)
                        NavigationLink(value: week) {
                            HStack(spacing: 14) {
                                Text(String(format: "%02d", week.number))
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(Theme.warm)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack {
                                        Text(week.theme).font(Theme.display(.title3)).fontWeight(.medium)
                                        if week.number == current.week {
                                            Text("THIS WEEK")
                                                .font(Theme.eyebrow)
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Theme.warmSoft, in: Capsule())
                                                .foregroundStyle(Theme.warm)
                                        }
                                    }
                                    Text(week.focus).font(.footnote).foregroundStyle(Theme.inkSoft).lineLimit(1)
                                    Text("Plan \(plan.filledFields)/\(ClassPlan.totalFields) · \(plan.tracks.count) tracks")
                                        .font(.system(.caption2, design: .monospaced))
                                        .foregroundStyle(Theme.inkSoft)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .navigationTitle("The Rotation")
            .navigationDestination(for: RotationWeek.self) { WeekDetailView(week: $0) }
        }
    }
}

struct WeekDetailView: View {
    @Environment(PlanStore.self) private var store
    let week: RotationWeek

    var body: some View {
        let plan = store.plan(for: week.number)
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Eyebrow("Week \(week.number) of 6", color: Theme.warm)
                    Text(week.theme).font(Theme.display(.largeTitle)).fontWeight(.medium)
                    Text(week.focus).foregroundStyle(Theme.inkSoft)
                }
                .padding(.vertical, 4)
            }
            Section("Peak") {
                Text(week.peak)
                    .listRowBackground(Theme.warmSoft)
            }
            Section("Prepares with") { Text(week.prepares) }
            Section("Counter") { Text(week.counter) }
            Section("Music") { Text(week.music) }
            Section("Your class") {
                NavigationLink {
                    PlanEditor(week: week, initial: plan)
                } label: {
                    LabeledContent("Class plan", value: "\(plan.filledFields)/\(ClassPlan.totalFields)")
                }
                NavigationLink {
                    PlaylistEditor(week: week, initial: plan)
                } label: {
                    LabeledContent("Playlist", value: plan.tracks.isEmpty ? "Empty" : "\(Fmt.clock(TimeInterval(plan.totalSeconds))) of \(Fmt.clock(TimeInterval(plan.targetSeconds)))")
                }
                ShareLink(item: plan.shareText(for: week)) {
                    Label("Share or print the one-page plan", systemImage: "square.and.arrow.up")
                }
            }
        }
        .navigationTitle("Week \(week.number)")
        .navigationBarTitleDisplayMode(.inline)
    }
}
