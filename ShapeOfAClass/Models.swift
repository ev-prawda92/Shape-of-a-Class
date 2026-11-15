import Foundation

enum ClassLength: Int, CaseIterable, Identifiable, Codable {
    case sixty = 60
    case seventyFive = 75

    var id: Int { rawValue }
    var minutes: Int { rawValue }
    var label: String { "\(rawValue) min" }
}

struct Phase: Identifiable, Hashable {
    let id: String
    let name: String
    let start60: Double
    let end60: Double
    let start75: Double
    let end75: Double
    let bpmLow: Int
    let bpmHigh: Int
    let music: String

    func start(_ length: ClassLength) -> Double { length == .sixty ? start60 : start75 }
    func end(_ length: ClassLength) -> Double { length == .sixty ? end60 : end75 }
    func duration(_ length: ClassLength) -> Double { end(length) - start(length) }
    var bpm: String { "\(bpmLow)–\(bpmHigh) bpm" }
    var isPeak: Bool { id == "peak" }
}

struct CurvePoint: Identifiable {
    let minute: Double
    let intensity: Double
    var id: Double { minute }
}

struct RotationWeek: Identifiable, Hashable {
    let number: Int
    let theme: String
    let focus: String
    let peak: String
    let prepares: String
    let counter: String
    let music: String
    var id: Int { number }
}

struct Track: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String = ""
    var artist: String = ""
    var seconds: Int = 240
    var phaseID: String = "arrival"
    var spotifyURI: String? = nil
}

struct ClassPlan: Codable, Hashable, Identifiable {
    var week: Int
    var length: ClassLength = .sixty
    var peakShape: String = ""
    var phaseNotes: [String: String] = [:]
    var peakTrack: String = ""
    var oneThing: String = ""
    var tracks: [Track] = []
    var updated: Date = .now

    var id: Int { week }

    var filledFields: Int {
        let notes = Content.phases.filter { !(phaseNotes[$0.id] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.count
        return notes + [peakShape, peakTrack, oneThing].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count
    }
    static let totalFields = Content.phases.count + 3
}

// MARK: - Playlist checks

struct PhaseAlignment: Identifiable {
    let phase: Phase
    let plannedSeconds: Int
    let neededSeconds: Int
    let startDrift: Int
    var id: String { phase.id }
}

extension ClassPlan {
    var totalSeconds: Int { tracks.reduce(0) { $0 + $1.seconds } }
    var targetSeconds: Int { (length.minutes + 5) * 60 }

    var orderedTracks: [Track] {
        Content.phases.flatMap { phase in tracks.filter { $0.phaseID == phase.id } }
    }

    func tracks(in phase: Phase) -> [Track] {
        tracks.filter { $0.phaseID == phase.id }
    }

    func track(at elapsed: TimeInterval) -> (track: Track, remaining: TimeInterval)? {
        var start: TimeInterval = 0
        for track in orderedTracks {
            let end = start + TimeInterval(track.seconds)
            if elapsed < end { return (track, end - elapsed) }
            start = end
        }
        return nil
    }

    var alignment: [PhaseAlignment] {
        var cursor = 0
        return Content.phases.map { phase in
            let planned = tracks(in: phase).reduce(0) { $0 + $1.seconds }
            let classStart = Int(phase.start(length) * 60)
            var needed = Int(phase.duration(length) * 60)
            if phase.id == "savasana" { needed += 5 * 60 }
            let result = PhaseAlignment(phase: phase, plannedSeconds: planned, neededSeconds: needed, startDrift: planned == 0 ? 0 : cursor - classStart)
            cursor += planned
            return result
        }
    }

    var warnings: [String] {
        var out: [String] = []
        if tracks.isEmpty { return out }
        let short = targetSeconds - totalSeconds
        if short > 0 {
            out.append("Playlist is \(Fmt.clock(TimeInterval(short))) short of class length plus five minutes. Savasana will end in silence if class runs over.")
        }
        for a in alignment where a.phase.id != "arrival" && a.plannedSeconds > 0 && abs(a.startDrift) > 60 {
            let when = a.startDrift > 0 ? "late" : "early"
            out.append("\(a.phase.name) music starts \(Fmt.clock(TimeInterval(abs(a.startDrift)))) \(when). The track change will land mid-transition.")
        }
        if let peak = Content.phases.first(where: { $0.isPeak }), tracks(in: peak).isEmpty {
            out.append("No track assigned to the peak yet. Put the one you picked first there.")
        }
        return out
    }

    func shareText(for week: RotationWeek) -> String {
        var lines: [String] = []
        lines.append("THE SHAPE OF A CLASS")
        lines.append("Week \(week.number) of 6: \(week.theme) · \(length.label)")
        lines.append("")
        lines.append("Peak shape: \(peakShape.isEmpty ? week.peak : peakShape)")
        lines.append("")
        for phase in Content.phases {
            let range = "\(Fmt.minute(phase.start(length)))–\(Fmt.minute(phase.end(length)))"
            lines.append("\(phase.name.uppercased())  \(range) min · \(phase.bpm)")
            let note = phaseNotes[phase.id] ?? ""
            lines.append(note.isEmpty ? "  ________________________" : "  " + note)
            for t in tracks(in: phase) {
                lines.append("  ♪ \(t.title.isEmpty ? "Untitled" : t.title)\(t.artist.isEmpty ? "" : " — \(t.artist)") (\(Fmt.clock(TimeInterval(t.seconds))))")
            }
            lines.append("")
        }
        lines.append("Peak track: \(peakTrack)")
        lines.append("One thing to say: \(oneThing)")
        if !tracks.isEmpty {
            lines.append("")
            lines.append("Playlist runs \(Fmt.clock(TimeInterval(totalSeconds))) (target \(Fmt.clock(TimeInterval(targetSeconds))))")
        }
        return lines.joined(separator: "\n")
    }
}

enum Fmt {
    static func clock(_ seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
    static func minute(_ m: Double) -> String {
        m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m)
    }
}

enum Rotation {
    static func current(start: Date, now: Date = .now) -> (week: Int, cycle: Int) {
        let cal = Calendar.current
        let days = cal.dateComponents([.day], from: cal.startOfDay(for: start), to: cal.startOfDay(for: now)).day ?? 0
        let weeks = max(0, days) / 7
        return (weeks % 6 + 1, weeks / 6 + 1)
    }
}
