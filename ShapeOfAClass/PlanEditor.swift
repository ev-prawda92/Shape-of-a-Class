import SwiftUI

struct PlanEditor: View {
    @Environment(PlanStore.self) private var store
    let week: RotationWeek
    @State private var plan: ClassPlan

    init(week: RotationWeek, initial: ClassPlan) {
        self.week = week
        _plan = State(initialValue: initial)
    }

    var body: some View {
        Form {
            Section {
                Picker("Length", selection: $plan.length) {
                    ForEach(ClassLength.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Fill it in the night before. Glance at it twice during class.")
            }

            Section("Peak shape") {
                TextField(week.peak, text: $plan.peakShape, axis: .vertical)
            }

            ForEach(Content.phases) { phase in
                Section {
                    TextField(placeholder(for: phase), text: noteBinding(phase), axis: .vertical)
                        .lineLimit(2...6)
                } header: {
                    HStack {
                        Text(phase.name)
                        Spacer()
                        Text("\(Fmt.minute(phase.start(plan.length)))–\(Fmt.minute(phase.end(plan.length))) · \(phase.bpm)")
                            .font(.system(.caption2, design: .monospaced))
                    }
                }
            }

            Section {
                TextField("The one you picked first", text: $plan.peakTrack)
            } header: {
                Text("Peak track")
            }

            Section {
                TextField("A single cue or idea", text: $plan.oneThing, axis: .vertical)
            } header: {
                Text("One thing to say")
            } footer: {
                Text("Once, not four times. It shows on the Teach screen during savasana.")
            }
        }
        .navigationTitle("\(week.theme) plan")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: plan.shareText(for: week)) {
                Image(systemName: "square.and.arrow.up")
            }
        }
        .onChange(of: plan) { _, newValue in store.save(newValue) }
    }

    private func noteBinding(_ phase: Phase) -> Binding<String> {
        Binding(
            get: { plan.phaseNotes[phase.id] ?? "" },
            set: { plan.phaseNotes[phase.id] = $0 }
        )
    }

    private func placeholder(for phase: Phase) -> String {
        switch phase.id {
        case "standing": return "Build toward: \(week.prepares)"
        case "peak": return "Cues, props, the quieter option"
        case "descent": return "Counter: \(week.counter)"
        default: return "Shapes and cues"
        }
    }
}
