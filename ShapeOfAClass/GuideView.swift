import SwiftUI

struct GuideView: View {
    @AppStorage("rotationStart") private var rotationStart: Double = 0

    private var startDate: Binding<Date> {
        Binding(
            get: { Date(timeIntervalSince1970: rotationStart == 0 ? Date.now.timeIntervalSince1970 : rotationStart) },
            set: { rotationStart = $0.timeIntervalSince1970 }
        )
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Playlist rules") {
                    ForEach(Array(Content.rules.enumerated()), id: \.element.id) { i, rule in
                        VStack(alignment: .leading, spacing: 6) {
                            Eyebrow(String(format: "Rule %02d", i + 1), color: Theme.cool)
                            Text(rule.title).font(Theme.display(.headline))
                            Text(rule.body).font(.subheadline).foregroundStyle(Theme.ink.opacity(0.75))
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Music licensing") {
                    Text(Content.licensing).font(.subheadline)
                }

                Section("Where this system is wrong") {
                    ForEach(Content.cautions) { c in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(c.title).font(.headline).foregroundStyle(Theme.plum)
                            Text(c.body).font(.subheadline).foregroundStyle(Theme.ink.opacity(0.75))
                        }
                        .padding(.vertical, 4)
                    }
                }

                SpotifyConnectSection()

                Section {
                    DatePicker("Week 1 started", selection: startDate, displayedComponents: .date)
                } header: {
                    Text("Your rotation")
                } footer: {
                    Text("The app counts forward from this date to show which week you're teaching.")
                }

                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("The Shape of a Class").font(Theme.display(.headline))
                        Text("By Evan Prawda").font(.footnote).foregroundStyle(Theme.inkSoft)
                    }
                }
            }
            .navigationTitle("Guide")
        }
    }
}
