import Foundation

enum Content {
    static let phases: [Phase] = [
        Phase(id: "arrival", name: "Arrival", start60: 0, end60: 7, start75: 0, end75: 8, bpmLow: 60, bpmHigh: 75,
              music: "Ambient or instrumental. Nothing with a narrative lyric. People are still arriving in their heads."),
        Phase(id: "warming", name: "Warming", start60: 7, end60: 15, start75: 8, end75: 19, bpmLow: 70, bpmHigh: 85,
              music: "The first pulse appears. Still soft, but a beat you could nod to."),
        Phase(id: "salutations", name: "Salutations", start60: 15, end60: 25, start75: 19, end75: 31, bpmLow: 85, bpmHigh: 100,
              music: "Tempo settles into something you can breathe to. Consistent, not building yet."),
        Phase(id: "standing", name: "Standing", start60: 25, end60: 38, start75: 31, end75: 48, bpmLow: 95, bpmHigh: 110,
              music: "The long working middle. Steady energy, no dramatic shifts. A track change here is the most disruptive."),
        Phase(id: "peak", name: "Peak", start60: 38, end60: 46, start75: 48, end75: 58, bpmLow: 100, bpmHigh: 115,
              music: "The one song you picked first. It goes here."),
        Phase(id: "descent", name: "Descent", start60: 46, end60: 54, start75: 58, end75: 68, bpmLow: 75, bpmHigh: 90,
              music: "Release. Warmth without drive. The tempo comes off before the shapes do."),
        Phase(id: "savasana", name: "Savasana", start60: 54, end60: 60, start75: 68, end75: 75, bpmLow: 55, bpmHigh: 70,
              music: "Drone, or silence. A track ending here will wake people up, so pick something long.")
    ]

    private static let curve60: [(Double, Double)] = [
        (0, 0.5), (7, 1.5), (15, 3), (25, 5.5), (33, 6.5), (38, 7), (42, 8.4), (46, 7.4), (50, 4), (54, 2.4), (60, 0.4)
    ]

    static let apex60: Double = 42

    /// Maps a minute on the 60-minute schedule onto the same point of the same phase for another length.
    static func remap(_ minute: Double, to length: ClassLength) -> Double {
        guard length != .sixty else { return minute }
        for p in phases where minute >= p.start60 && minute <= p.end60 {
            let f = (minute - p.start60) / (p.end60 - p.start60)
            return p.start75 + f * (p.end75 - p.start75)
        }
        return minute
    }

    static func curve(for length: ClassLength) -> [CurvePoint] {
        curve60.map { CurvePoint(minute: remap($0.0, to: length), intensity: $0.1) }
    }

    static func apex(for length: ClassLength) -> Double { remap(apex60, to: length) }

    static func phase(at minute: Double, length: ClassLength) -> Phase? {
        phases.first { minute >= $0.start(length) && minute < $0.end(length) }
    }

    static let weeks: [RotationWeek] = [
        RotationWeek(number: 1, theme: "Ground",
                     focus: "Hips, and the feeling of weight going down",
                     peak: "Eka Pada Rajakapotasana, upright variation, long hold",
                     prepares: "Low lunge, figure-four at the wall, thread the needle, Ardha Matsyendrasana",
                     counter: "Supine twist, then legs long",
                     music: "Low and warm throughout. The peak track can be almost still."),
        RotationWeek(number: 2, theme: "Lengthen",
                     focus: "Hamstrings and the back line, patiently",
                     peak: "Ardha Hanumanasana to a supported half split, blocks under the hands",
                     prepares: "Downward dog with bent knees, Uttanasana with a bend, lunge to hamstring rock, pyramid",
                     counter: "Supported bridge, knees to chest",
                     music: "Spacious. Long tracks, since this class has fewer transitions than most."),
        RotationWeek(number: 3, theme: "Wring",
                     focus: "Twists, and breath into the side body",
                     peak: "Parivrtta Parsvakonasana, back knee down as the standing option",
                     prepares: "Cat-cow with a twist, revolved lunge, revolved triangle prep, seated twist",
                     counter: "Wide child's pose, then a symmetrical forward fold",
                     music: "Rhythmic and a little percussive. Twists reward a pulse."),
        RotationWeek(number: 4, theme: "Open",
                     focus: "Front body, shoulders, the heart shapes",
                     peak: "Ustrasana, hands on blocks or sacrum. Then come down to the belly for a soft Dhanurasana",
                     prepares: "Sphinx, low lunge with a backbend, Anahatasana, bridge with a strap",
                     counter: "Knees to chest and a gentle twist. No deep forward fold right away",
                     music: "The most emotional week. A track with a real swell earns its place here."),
        RotationWeek(number: 5, theme: "Steady",
                     focus: "Balance, ankles, and attention",
                     peak: "Ardha Chandrasana at the wall, then free, block under the low hand",
                     prepares: "Tadasana with eyes closed, Vrksasana, Warrior III at the wall, extended side angle",
                     counter: "Standing forward fold, then seated",
                     music: "Steady and unobtrusive. Balance classes go badly over anything busy."),
        RotationWeek(number: 6, theme: "Invert",
                     focus: "Shoulders overhead, and being upside down without drama",
                     peak: "Dolphin, then legs up the wall or supported bridge on a block. Salamba Sarvangasana on blankets only for students with an established practice",
                     prepares: "Shoulder openers at the wall, forearm plank, downward dog holds",
                     counter: "Supported Matsyasana, long savasana",
                     music: "Quiet and even. Nobody wants a drop while they're upside down.")
    ]

    struct Rule: Identifiable {
        let title: String
        let body: String
        var id: String { title }
    }

    static let rules: [Rule] = [
        Rule(title: "Change tracks at phase boundaries, never mid-transition",
             body: "A song ending while someone is halfway into a shape pulls their attention out of their body. Build the playlist so changes land in the pauses you already planned."),
        Rule(title: "Put your favorite track at the peak, not the start",
             body: "The song you picked first almost always has the most lift in it, and lift is what the apex needs. Open with something nobody notices."),
        Rule(title: "Build five minutes longer than the class",
             body: "Classes run over. Silence arriving during savasana because the playlist ended is worse than any wrong song."),
        Rule(title: "No familiar lyrics in the quiet phases",
             body: "A song people know pulls them into remembering rather than sensing. Save recognizable music for the working middle."),
        Rule(title: "Let the tempo come off before the shapes do",
             body: "Drop the BPM about two minutes before the descent. The room settles ahead of your cue."),
        Rule(title: "One playlist per rotation week, reused",
             body: "Six playlists, not fifty-two. They improve every cycle, regulars start to recognize the week by its sound, and you stop rebuilding one every Sunday night.")
    ]

    static let whyRotation = "Six weeks is long enough that nothing feels repetitive and short enough that regulars meet the same peak again while they still remember the last attempt. Progress in yoga is mostly invisible unless someone gets to notice it. A rotation is how you engineer the noticing. Say so out loud when the cycle comes back around."

    static let whyArc = "A class has an energy curve whether or not you plan one, and so does a playlist. When the two drift, the track that should carry the peak arrives during warm-ups. Students feel that mismatch without being able to name it. In slow flow the apex sits around two-thirds through and reaches maybe eight out of ten. The descent is long and deliberate, because the second half is the point, not the cooldown."

    static let licensing = "A personal Spotify or Apple Music account is licensed for personal listening, not for classes you teach to the public. Studios usually cover public performance through licenses from music rights organizations (in the US: ASCAP, BMI, SESAC and GMR), or through a service built for fitness instructors. Ask the studio what they hold before you press play. If you teach independently, the licensing is on you."

    static let cautions: [Rule] = [
        Rule(title: "The BPM bands are a starting point",
             body: "Plenty of great slow flow music has no discernible tempo. Use the bands where they help and ignore them where a track is obviously right."),
        Rule(title: "A rotation can become a rut",
             body: "Around the sixth cycle a system turns into autopilot. Rebuild the peaks, keep the architecture, roughly twice a year."),
        Rule(title: "The plan never outranks the room",
             body: "If eight people arrive exhausted on a Thursday, the peak doesn't happen that night. The plan exists so you have something to abandon deliberately."),
        Rule(title: "The asana picks are suggestions",
             body: "The architecture is what matters. Swap any peak for shapes you teach well and your students are ready for, and always offer the quieter option.")
    ]
}
