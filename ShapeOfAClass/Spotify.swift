import SwiftUI
import AuthenticationServices
import CryptoKit
import Security
import Observation

struct SpotifyPlaylist: Identifiable, Hashable {
    let id: String
    let name: String
    let total: Int
    let isOwn: Bool
}

struct SpotifyTrack: Hashable {
    let uri: String
    let name: String
    let artists: String
    let seconds: Int
}

struct SpotifyDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let type: String
    let isActive: Bool
}

struct NowPlaying: Hashable {
    let uri: String
    let title: String
    let artist: String
}

struct SpotifyToken: Codable {
    var access: String
    var refresh: String
    var expires: Date
}

enum SpotifyError: LocalizedError {
    case notConnected
    case missingClientID
    case auth(String)
    case notYourPlaylist
    case api(Int, String)
    case network

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "Spotify isn't connected. Connect it in the Guide tab."
        case .missingClientID:
            return "Paste your Spotify Client ID first."
        case .auth(let detail):
            return "Spotify sign-in didn't finish. Check the Client ID, the redirect URI, and that your account is added under User Management. (\(detail))"
        case .notYourPlaylist:
            return "Spotify only shares the songs in playlists you own or collaborate on. Copy this playlist into one of your own, then import that."
        case .api(let status, let message):
            switch status {
            case 403 where message.localizedCaseInsensitiveContains("premium"):
                return "Playback control needs Spotify Premium."
            case 403:
                return "Spotify refused the request. Make sure this account is added to the app's User Management list. (\(message))"
            case 404:
                return "No active Spotify device. Open Spotify on this phone or your speaker, then refresh devices."
            case 429:
                return "Spotify is rate limiting requests. Wait a minute and try again."
            default:
                return "Spotify error \(status): \(message)"
            }
        case .network:
            return "Couldn't reach Spotify. Check the connection."
        }
    }
}

enum Keychain {
    private static let service = "com.evanprawda.shapeofaclass"

    static func set(_ data: Data, for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    static func delete(_ key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        SecItemDelete(query as CFDictionary)
    }
}

extension Data {
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

@MainActor
@Observable
final class SpotifyController {
    static let redirectURI = "shapeofaclass://spotify-callback"
    static let callbackScheme = "shapeofaclass"
    private static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing"
    ].joined(separator: " ")

    private(set) var token: SpotifyToken?
    private(set) var userName: String = UserDefaults.standard.string(forKey: "spotifyUserName") ?? ""
    private(set) var devices: [SpotifyDevice] = []
    private(set) var nowPlaying: NowPlaying?
    private(set) var isClassActive = false
    var message: String?
    var selectedDeviceID: String = UserDefaults.standard.string(forKey: "spotifyDevice") ?? "" {
        didSet { UserDefaults.standard.set(selectedDeviceID, forKey: "spotifyDevice") }
    }

    var isConnected: Bool { token != nil }

    private var userID: String = UserDefaults.standard.string(forKey: "spotifyUserID") ?? ""
    private var uris: [String] = []
    private var phaseFirstIndex: [String: Int] = [:]
    private var length: ClassLength = .sixty
    private var classStart: Date?
    private var pausedTotal: TimeInterval = 0
    private var pauseStart: Date?
    private var lastPhase: String?
    private var tickCount = 0
    private var timer: Timer?

    init() {
        if let data = Keychain.get("spotifyToken"),
           let saved = try? JSONDecoder().decode(SpotifyToken.self, from: data) {
            token = saved
        }
    }

    // MARK: Auth

    func connect(clientID rawID: String, session: WebAuthenticationSession) async {
        message = nil
        let clientID = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clientID.isEmpty else {
            message = SpotifyError.missingClientID.localizedDescription
            return
        }
        UserDefaults.standard.set(clientID, forKey: "spotifyClientID")

        let verifier = Self.randomString(64)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(16)

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state)
        ]

        do {
            let callback = try await session.authenticate(using: comps.url!,
                                                          callbackURLScheme: Self.callbackScheme,
                                                          preferredBrowserSession: .ephemeral)
            let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
            if let err = items.first(where: { $0.name == "error" })?.value {
                throw SpotifyError.auth(err)
            }
            guard items.first(where: { $0.name == "state" })?.value == state,
                  let code = items.first(where: { $0.name == "code" })?.value else {
                throw SpotifyError.auth("no authorization code returned")
            }
            let newToken = try await tokenRequest([
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "client_id": clientID,
                "code_verifier": verifier
            ])
            save(newToken)
            try await loadProfile()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            message = error.localizedDescription
        }
    }

    func disconnect() {
        endClass()
        token = nil
        userName = ""
        userID = ""
        devices = []
        Keychain.delete("spotifyToken")
        UserDefaults.standard.removeObject(forKey: "spotifyUserName")
        UserDefaults.standard.removeObject(forKey: "spotifyUserID")
    }

    private func save(_ newToken: SpotifyToken) {
        token = newToken
        if let data = try? JSONEncoder().encode(newToken) {
            Keychain.set(data, for: "spotifyToken")
        }
    }

    private func loadProfile() async throws {
        let (data, http) = try await send("GET", "/me")
        try check(http, data)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        userID = obj["id"] as? String ?? ""
        userName = (obj["display_name"] as? String) ?? userID
        UserDefaults.standard.set(userID, forKey: "spotifyUserID")
        UserDefaults.standard.set(userName, forKey: "spotifyUserName")
    }

    private func tokenRequest(_ params: [String: String]) async throws -> SpotifyToken {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = params
            .map { "\($0.key)=\(Self.formEncode($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let access = obj["access_token"] as? String else {
            let body = String(data: data, encoding: .utf8) ?? "unknown error"
            throw SpotifyError.auth(body)
        }
        let expiresIn = (obj["expires_in"] as? NSNumber)?.doubleValue ?? 3600
        return SpotifyToken(access: access,
                            refresh: obj["refresh_token"] as? String ?? params["refresh_token"] ?? "",
                            expires: Date.now.addingTimeInterval(expiresIn))
    }

    private func validAccessToken(forceRefresh: Bool) async throws -> String {
        guard let current = token else { throw SpotifyError.notConnected }
        if forceRefresh || current.expires < Date.now.addingTimeInterval(60) {
            guard let clientID = UserDefaults.standard.string(forKey: "spotifyClientID"), !current.refresh.isEmpty else {
                disconnect()
                throw SpotifyError.notConnected
            }
            do {
                let refreshed = try await tokenRequest([
                    "grant_type": "refresh_token",
                    "refresh_token": current.refresh,
                    "client_id": clientID
                ])
                save(refreshed)
                return refreshed.access
            } catch {
                disconnect()
                throw SpotifyError.notConnected
            }
        }
        return current.access
    }

    // MARK: Web API

    private func send(_ method: String, _ path: String, query: [URLQueryItem] = [], json: Any? = nil) async throws -> (Data, HTTPURLResponse) {
        var comps = URLComponents(string: "https://api.spotify.com/v1" + path)!
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw SpotifyError.network }

        for attempt in 0..<2 {
            let access = try await validAccessToken(forceRefresh: attempt == 1)
            var req = URLRequest(url: url)
            req.httpMethod = method
            req.setValue("Bearer \(access)", forHTTPHeaderField: "Authorization")
            if let json {
                req.httpBody = try JSONSerialization.data(withJSONObject: json)
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            } else if method == "PUT" || method == "POST" {
                req.httpBody = Data()
            }
            guard let fetched = try? await URLSession.shared.data(for: req) else {
                throw SpotifyError.network
            }
            let data = fetched.0
            let resp = fetched.1
            guard let http = resp as? HTTPURLResponse else { throw SpotifyError.network }
            if http.statusCode == 401 && attempt == 0 { continue }
            return (data, http)
        }
        throw SpotifyError.notConnected
    }

    private func check(_ http: HTTPURLResponse, _ data: Data) throws {
        guard !(200..<300).contains(http.statusCode) else { return }
        var text = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let err = obj["error"] as? [String: Any] {
            let parts = [err["message"] as? String, err["reason"] as? String].compactMap { $0 }
            if !parts.isEmpty { text = parts.joined(separator: " · ") }
        }
        throw SpotifyError.api(http.statusCode, text)
    }

    private static func dicts(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { $0 as? [String: Any] } ?? []
    }

    private static func hasNext(_ obj: [String: Any]) -> Bool {
        guard let next = obj["next"] else { return false }
        return next is String
    }

    func loadPlaylists() async throws -> [SpotifyPlaylist] {
        if userID.isEmpty { try await loadProfile() }
        var out: [SpotifyPlaylist] = []
        var offset = 0
        while offset < 500 {
            let (data, http) = try await send("GET", "/me/playlists", query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            try check(http, data)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let items = Self.dicts(obj["items"])
            for p in items {
                guard let id = p["id"] as? String else { continue }
                let owner = (p["owner"] as? [String: Any])?["id"] as? String
                let collaborative = p["collaborative"] as? Bool ?? false
                let totals = (p["items"] as? [String: Any]) ?? (p["tracks"] as? [String: Any])
                out.append(SpotifyPlaylist(id: id,
                                           name: p["name"] as? String ?? "Untitled",
                                           total: totals?["total"] as? Int ?? 0,
                                           isOwn: owner == userID || collaborative))
            }
            if !Self.hasNext(obj) || items.isEmpty { break }
            offset += 50
        }
        return out
    }

    func loadTracks(playlistID: String) async throws -> [SpotifyTrack] {
        var out: [SpotifyTrack] = []
        var offset = 0
        while offset < 1000 {
            let (data, http) = try await send("GET", "/playlists/\(playlistID)/items", query: [
                URLQueryItem(name: "limit", value: "50"),
                URLQueryItem(name: "offset", value: String(offset))
            ])
            if http.statusCode == 403 || http.statusCode == 404 { throw SpotifyError.notYourPlaylist }
            try check(http, data)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            let entries = Self.dicts(obj["items"])
            for entry in entries {
                guard let track = (entry["item"] as? [String: Any]) ?? (entry["track"] as? [String: Any]),
                      (track["type"] as? String ?? "track") == "track",
                      let uri = track["uri"] as? String,
                      !uri.hasPrefix("spotify:local"),
                      let ms = (track["duration_ms"] as? NSNumber)?.doubleValue else { continue }
                let artists = Self.dicts(track["artists"]).compactMap { $0["name"] as? String }.joined(separator: ", ")
                out.append(SpotifyTrack(uri: uri,
                                        name: track["name"] as? String ?? "Untitled",
                                        artists: artists,
                                        seconds: Int((ms / 1000).rounded())))
            }
            if !Self.hasNext(obj) || entries.isEmpty { break }
            offset += 50
        }
        if out.isEmpty && offset == 0 {
            throw SpotifyError.notYourPlaylist
        }
        return out
    }

    static func assignPhases(_ tracks: [SpotifyTrack], length: ClassLength) -> [Track] {
        var cursor: Double = 0
        return tracks.map { t in
            let phase = Content.phase(at: cursor / 60, length: length) ?? Content.phases[Content.phases.count - 1]
            cursor += Double(t.seconds)
            return Track(title: t.name, artist: t.artists, seconds: t.seconds, phaseID: phase.id, spotifyURI: t.uri)
        }
    }

    // MARK: Devices and playback

    func refreshDevices() async {
        do {
            let (data, http) = try await send("GET", "/me/player/devices")
            try check(http, data)
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
            devices = Self.dicts(obj["devices"]).compactMap { d in
                guard let id = d["id"] as? String else { return nil }
                return SpotifyDevice(id: id,
                                     name: d["name"] as? String ?? "Device",
                                     type: d["type"] as? String ?? "",
                                     isActive: d["is_active"] as? Bool ?? false)
            }
            if !devices.contains(where: { $0.id == selectedDeviceID }) {
                selectedDeviceID = devices.first(where: { $0.isActive })?.id
                    ?? devices.first(where: { $0.type == "Smartphone" })?.id
                    ?? devices.first?.id
                    ?? ""
            }
            message = devices.isEmpty ? "No Spotify devices found. Open Spotify on this phone or on your speaker, then refresh." : nil
        } catch {
            message = error.localizedDescription
        }
    }

    private var deviceQuery: [URLQueryItem] {
        selectedDeviceID.isEmpty ? [] : [URLQueryItem(name: "device_id", value: selectedDeviceID)]
    }

    private func play(offset: Int) async throws {
        let body: [String: Any] = [
            "uris": uris,
            "offset": ["position": offset],
            "position_ms": 0
        ]
        let (data, http) = try await send("PUT", "/me/player/play", query: deviceQuery, json: body)
        try check(http, data)
    }

    private func currentlyPlaying() async -> NowPlaying? {
        guard let result = try? await send("GET", "/me/player/currently-playing") else { return nil }
        let (data, http) = result
        guard http.statusCode == 200,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let item = obj["item"] as? [String: Any],
              let uri = item["uri"] as? String else { return nil }
        let artists = Self.dicts(item["artists"]).compactMap { $0["name"] as? String }.joined(separator: ", ")
        return NowPlaying(uri: uri, title: item["name"] as? String ?? "", artist: artists)
    }

    func startClass(plan: ClassPlan, length: ClassLength) async {
        let tracks = plan.orderedTracks.filter { $0.spotifyURI != nil }
        guard !tracks.isEmpty else { return }
        uris = tracks.compactMap { $0.spotifyURI }
        phaseFirstIndex = [:]
        for (i, t) in tracks.enumerated() where phaseFirstIndex[t.phaseID] == nil {
            phaseFirstIndex[t.phaseID] = i
        }
        self.length = length
        classStart = .now
        pausedTotal = 0
        pauseStart = nil
        lastPhase = nil
        tickCount = 0
        isClassActive = true

        do {
            if selectedDeviceID.isEmpty { await refreshDevices() }
            try await play(offset: 0)
            message = nil
        } catch {
            message = error.localizedDescription
        }

        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func pauseClass() {
        guard isClassActive, pauseStart == nil else { return }
        pauseStart = .now
        let query = deviceQuery
        Task {
            _ = try? await send("PUT", "/me/player/pause", query: query)
        }
    }

    func resumeClass() {
        guard isClassActive, let started = pauseStart else { return }
        pausedTotal += Date.now.timeIntervalSince(started)
        pauseStart = nil
        let query = deviceQuery
        Task {
            if let result = try? await send("PUT", "/me/player/play", query: query) {
                do { try check(result.1, result.0) } catch { message = error.localizedDescription }
            }
        }
    }

    func endClass() {
        guard isClassActive else { return }
        timer?.invalidate()
        timer = nil
        isClassActive = false
        nowPlaying = nil
        classStart = nil
        let query = deviceQuery
        Task {
            _ = try? await send("PUT", "/me/player/pause", query: query)
        }
    }

    private func tick() {
        guard isClassActive, pauseStart == nil, let classStart else { return }
        let elapsed = Date.now.timeIntervalSince(classStart) - pausedTotal
        tickCount += 1

        if let phase = Content.phase(at: elapsed / 60, length: length), phase.id != lastPhase {
            let isFirst = lastPhase == nil
            lastPhase = phase.id
            let keepOnArc = UserDefaults.standard.object(forKey: "spotifyKeepOnArc") as? Bool ?? true
            if !isFirst, keepOnArc, let index = phaseFirstIndex[phase.id] {
                Task { await align(to: index) }
            }
        }
        if tickCount % 5 == 1 {
            Task { nowPlaying = await currentlyPlaying() }
        }
    }

    private func align(to index: Int) async {
        let current = await currentlyPlaying()
        let position = current.flatMap { np in uris.firstIndex(of: np.uri) }
        if position == nil || position! < index {
            do {
                try await play(offset: index)
            } catch {
                message = error.localizedDescription
            }
        }
    }

    // MARK: Helpers

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        var generator = SystemRandomNumberGenerator()
        return String((0..<length).map { _ in chars[Int(generator.next() % UInt64(chars.count))] })
    }

    private static func formEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

// MARK: - Views

struct SpotifyConnectSection: View {
    @Environment(SpotifyController.self) private var spotify
    @Environment(\.webAuthenticationSession) private var webAuth
    @AppStorage("spotifyClientID") private var clientID: String = ""
    @State private var working = false

    var body: some View {
        Section {
            if spotify.isConnected {
                LabeledContent("Connected as", value: spotify.userName.isEmpty ? "Spotify user" : spotify.userName)
                Button("Disconnect Spotify", role: .destructive) {
                    spotify.disconnect()
                }
            } else {
                TextField("Spotify Client ID", text: $clientID)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.system(.body, design: .monospaced))
                Button {
                    working = true
                    Task {
                        await spotify.connect(clientID: clientID, session: webAuth)
                        working = false
                    }
                } label: {
                    HStack {
                        Text("Connect Spotify")
                        if working {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(clientID.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            if let message = spotify.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(Theme.plum)
            }
        } header: {
            Text("Spotify (pilot)")
        } footer: {
            Text("Create an app at developer.spotify.com/dashboard. Choose Web API, add the redirect URI \(SpotifyController.redirectURI), and add each pilot teacher's Spotify email under User Management (5 people maximum, including you). Paste the Client ID here. Playback needs Premium.")
        }
    }
}

struct SpotifyImportSheet: View {
    @Environment(SpotifyController.self) private var spotify
    @Environment(\.dismiss) private var dismiss
    let length: ClassLength
    let replacing: Bool
    let onImport: ([Track]) -> Void

    @State private var playlists: [SpotifyPlaylist] = []
    @State private var loading = true
    @State private var errorText: String?
    @State private var importingID: String?

    var body: some View {
        NavigationStack {
            Group {
                if !spotify.isConnected {
                    ContentUnavailableView("Spotify isn't connected",
                                           systemImage: "link",
                                           description: Text("Connect Spotify in the Guide tab first."))
                } else if loading {
                    ProgressView("Loading your playlists")
                } else if playlists.isEmpty {
                    ContentUnavailableView("No playlists",
                                           systemImage: "music.note.list",
                                           description: Text(errorText ?? "Make a playlist in Spotify, then try again."))
                } else {
                    List {
                        if let errorText {
                            Text(errorText)
                                .font(.footnote)
                                .foregroundStyle(Theme.plum)
                        }
                        Section {
                            ForEach(playlists) { playlist in
                                Button {
                                    Task { await importPlaylist(playlist) }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(playlist.name).foregroundStyle(Theme.ink)
                                            Text(playlist.isOwn ? "\(playlist.total) tracks" : "Not yours · Spotify won't share its songs")
                                                .font(.caption)
                                                .foregroundStyle(playlist.isOwn ? Theme.inkSoft : Theme.plum)
                                        }
                                        Spacer()
                                        if importingID == playlist.id {
                                            ProgressView()
                                        }
                                    }
                                }
                                .disabled(importingID != nil)
                            }
                        } footer: {
                            Text((replacing ? "Importing replaces the tracks already in this playlist. " : "") + "Songs are placed into phases in order, by length. You can move any track to another phase afterward.")
                        }
                    }
                }
            }
            .navigationTitle("Import from Spotify")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .task {
                guard spotify.isConnected else { return }
                do {
                    playlists = try await spotify.loadPlaylists()
                } catch {
                    errorText = error.localizedDescription
                }
                loading = false
            }
        }
    }

    private func importPlaylist(_ playlist: SpotifyPlaylist) async {
        importingID = playlist.id
        errorText = nil
        do {
            let tracks = try await spotify.loadTracks(playlistID: playlist.id)
            importingID = nil
            onImport(SpotifyController.assignPhases(tracks, length: length))
            dismiss()
        } catch {
            importingID = nil
            errorText = error.localizedDescription
        }
    }
}

struct SpotifyClassCard: View {
    @Environment(SpotifyController.self) private var spotify
    @Environment(\.openURL) private var openURL
    @AppStorage("playOnSpotify") private var playOnSpotify: Bool = true
    @AppStorage("spotifyKeepOnArc") private var keepOnArc: Bool = true
    let plan: ClassPlan

    var body: some View {
        let count = plan.tracks.filter { $0.spotifyURI != nil }.count
        if count > 0 {
            Card {
                Toggle(isOn: $playOnSpotify) {
                    Label("Play on Spotify", systemImage: "music.note.list")
                }
                if !spotify.isConnected {
                    Text("Connect Spotify in the Guide tab to play this playlist.")
                        .font(.caption)
                        .foregroundStyle(Theme.plum)
                } else if playOnSpotify {
                    Text("\(count) tracks start with class, in phase order.")
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                    Picker("Play on", selection: Binding(get: { spotify.selectedDeviceID },
                                                         set: { spotify.selectedDeviceID = $0 })) {
                        Text("Choose a device").tag("")
                        ForEach(spotify.devices) { device in
                            Text(device.name + (device.isActive ? " · active" : "")).tag(device.id)
                        }
                    }
                    HStack {
                        Button("Refresh devices") {
                            Task { await spotify.refreshDevices() }
                        }
                        Spacer()
                        Button("Open Spotify") {
                            if let url = URL(string: "spotify:") { openURL(url) }
                        }
                    }
                    .font(.footnote)
                    .buttonStyle(.borderless)
                    Toggle("Keep music on the arc", isOn: $keepOnArc)
                        .font(.subheadline)
                    Text("When a phase starts and the last phase's music is still playing, skip ahead to this phase's first track.")
                        .font(.caption2)
                        .foregroundStyle(Theme.inkSoft)
                }
                if let message = spotify.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(Theme.plum)
                }
            }
            .task {
                if spotify.isConnected && playOnSpotify {
                    await spotify.refreshDevices()
                }
            }
        }
    }
}

struct SpotifyNowPlayingBadge: View {
    @Environment(SpotifyController.self) private var spotify

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note")
                .foregroundStyle(Theme.cool)
            VStack(alignment: .leading, spacing: 2) {
                Text(spotify.nowPlaying?.title ?? "Starting Spotify…")
                    .font(.subheadline)
                    .lineLimit(1)
                if let artist = spotify.nowPlaying?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.caption)
                        .foregroundStyle(Theme.inkSoft)
                        .lineLimit(1)
                }
                if let message = spotify.message {
                    Text(message)
                        .font(.caption2)
                        .foregroundStyle(Theme.plum)
                }
            }
            Spacer()
            Eyebrow("Spotify", color: Theme.cool)
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
