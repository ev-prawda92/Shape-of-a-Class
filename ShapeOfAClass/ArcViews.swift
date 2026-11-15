import SwiftUI
import Charts

struct ArcChart: View {
    let length: ClassLength
    var nowMinute: Double? = nil

    var body: some View {
        let points = Content.curve(for: length)
        let apex = Content.apex(for: length)
        Chart {
            ForEach(Array(Content.phases.enumerated()), id: \.element.id) { index, phase in
                RectangleMark(
                    xStart: .value("Start", phase.start(length)),
                    xEnd: .value("End", phase.end(length)),
                    yStart: .value("Low", 0),
                    yEnd: .value("High", 10)
                )
                .foregroundStyle(phase.isPeak ? Theme.warm.opacity(0.12) : Theme.ink.opacity(index % 2 == 0 ? 0.02 : 0.05))
            }
            ForEach(points) { p in
                AreaMark(x: .value("Minute", p.minute), y: .value("Intensity", p.intensity), series: .value("Series", "area"))
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(LinearGradient(colors: [Theme.warm.opacity(0.28), Theme.warm.opacity(0.02)], startPoint: .top, endPoint: .bottom))
            }
            ForEach(points) { p in
                LineMark(x: .value("Minute", p.minute), y: .value("Intensity", p.intensity), series: .value("Series", "curve"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round))
                    .foregroundStyle(Theme.warm)
            }
            PointMark(x: .value("Minute", apex), y: .value("Intensity", 8.4))
                .foregroundStyle(Theme.plum)
                .symbolSize(70)
                .annotation(position: .top) {
                    Text("apex · \(Fmt.minute(apex))")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.plum)
                }
            if let nowMinute {
                RuleMark(x: .value("Now", nowMinute))
                    .foregroundStyle(Theme.cool)
                    .lineStyle(StrokeStyle(lineWidth: 2))
            }
        }
        .chartYScale(domain: 0...10)
        .chartXScale(domain: 0...Double(length.minutes))
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: length == .sixty ? 10 : 15)) { _ in
                AxisGridLine().foregroundStyle(Theme.ink.opacity(0.08))
                AxisValueLabel().font(.system(.caption2, design: .monospaced))
            }
        }
        .accessibilityLabel("Energy curve across a \(length.minutes)-minute class, peaking around minute \(Fmt.minute(apex)).")
    }
}

struct ArcScreen: View {
    @AppStorage("classLength") private var lengthRaw: Int = 60
    private var length: ClassLength { ClassLength(rawValue: lengthRaw) ?? .sixty }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Picker("Length", selection: $lengthRaw) {
                        ForEach(ClassLength.allCases) { Text($0.label).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented)

                    Card {
                        Eyebrow("Intensity over \(length.minutes) minutes")
                        ArcChart(length: length).frame(height: 200)
                    }

                    Text(Content.whyArc)
                        .font(.callout)
                        .foregroundStyle(Theme.ink.opacity(0.8))

                    ForEach(Content.phases) { phase in
                        Card {
                            HStack(alignment: .firstTextBaseline) {
                                Text(phase.name).font(Theme.display(.title3)).fontWeight(.medium)
                                Spacer()
                                Text("\(Fmt.minute(phase.start(length)))–\(Fmt.minute(phase.end(length))) min")
                                    .font(.system(.footnote, design: .monospaced))
                                    .foregroundStyle(Theme.inkSoft)
                            }
                            Text(phase.bpm)
                                .font(.system(.footnote, design: .monospaced))
                                .foregroundStyle(Theme.warm)
                            Text(phase.music).font(.subheadline)
                        }
                        .overlay(alignment: .leading) {
                            if phase.isPeak {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.warm).frame(width: 3).padding(.vertical, 10)
                            }
                        }
                    }
                }
                .padding()
            }
            .background(Theme.ground)
            .navigationTitle("The Arc")
        }
    }
}
