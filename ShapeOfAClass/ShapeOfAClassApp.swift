import SwiftUI

@main
struct ShapeOfAClassApp: App {
    @State private var store = PlanStore()
    @State private var recordings = RecordingStore()
    @State private var recorder = ClassRecorder()
    @State private var video = VideoRecorder()
    @State private var spotify = SpotifyController()
    @AppStorage("rotationStart") private var rotationStart: Double = 0

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(recordings)
                .environment(recorder)
                .environment(video)
                .environment(spotify)
                .tint(Theme.warm)
                .onAppear {
                    if rotationStart == 0 { rotationStart = Date.now.timeIntervalSince1970 }
                }
        }
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            TeachView()
                .tabItem { Label("Teach", systemImage: "timer") }
            RecordingsView()
                .tabItem { Label("Classes", systemImage: "waveform") }
            ArcScreen()
                .tabItem { Label("Arc", systemImage: "waveform.path") }
            RotationView()
                .tabItem { Label("Weeks", systemImage: "calendar") }
            GuideView()
                .tabItem { Label("Guide", systemImage: "book") }
        }
    }
}
