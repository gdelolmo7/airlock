import AppKit
import Foundation

/// A playing track, as one immutable observation.
struct MediaPlayerState: Equatable {
    var player: MediaPlayerKind
    var isPlaying: Bool
    var title: String
    var artist: String
    var artworkURL: URL?
    /// Seconds at `fetchedAt`; the UI interpolates forward while playing.
    var position: TimeInterval
    var duration: TimeInterval
    var fetchedAt: Date

    /// Clamped to the total only when there IS one. A live stream reports
    /// `duration == 0`, and clamping unconditionally pinned its elapsed clock at
    /// 0:00 forever — invisible while the zero-duration case rendered nothing,
    /// and the only number that case has to show now that it does.
    func interpolatedPosition(at now: Date) -> TimeInterval {
        guard isPlaying else { return position }
        let elapsed = position + now.timeIntervalSince(fetchedAt)
        return duration > 0 ? min(elapsed, duration) : elapsed
    }
}

enum MediaPlayerKind: String, CaseIterable, Codable {
    case spotify
    case appleMusic

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .appleMusic: return "com.apple.Music"
        }
    }

    var scriptTarget: String {
        switch self {
        case .spotify: return "Spotify"
        case .appleMusic: return "Music"
        }
    }

    /// Whether this player's scripting interface lets us MOVE the playhead, as
    /// opposed to only reading it.
    ///
    /// Checked, not assumed. Both shipping players declare `player position`
    /// (`pPos`, type `real`, seconds) without `access="r"`, so both are
    /// writable — verified against the installed apps' own dictionaries
    /// (`sdef /System/Applications/Music.app`, `sdef /Applications/Spotify.app`)
    /// rather than taken from documentation. It is a property per player and not
    /// a `true` hard-coded at the call site precisely because the answer belongs
    /// to the player: the day one arrives that can only report position, the bar
    /// has to stop pretending rather than swallow drags in silence.
    var canSeek: Bool {
        switch self {
        case .spotify, .appleMusic: return true
        }
    }

    /// Distributed notification each player posts on playback changes —
    /// the push channel that makes polling almost unnecessary.
    var changeNotification: Notification.Name {
        switch self {
        case .spotify: return Notification.Name("com.spotify.client.PlaybackStateChanged")
        case .appleMusic: return Notification.Name("com.apple.Music.playerInfo")
        }
    }
}

/// Talks to one player over its public scripting interface.
///
/// CRITICAL invariant: never send an Apple event to a player that isn't
/// running — AppleScript LAUNCHES the target app. Every path checks
/// `isRunning` (NSWorkspace, no permission needed) first.
struct MediaPlayerController: Sendable {
    let kind: MediaPlayerKind

    nonisolated var isRunning: Bool {
        NSWorkspace.shared.runningApplications
            .contains { $0.bundleIdentifier == kind.bundleID }
    }

    /// What one fetch found.
    ///
    /// `refused` is its own answer because it used to be nil, like "nothing
    /// loaded": with Automation turned off the card simply vanished and read as
    /// "nothing playing" while Spotify played on.
    enum Fetch: Equatable {
        case playing(MediaPlayerState)
        case nothing
        /// macOS refused the Apple event: Automation is off for this player.
        case refused
    }

    /// One-shot state fetch.
    func fetch() async -> Fetch {
        guard isRunning else { return .nothing }
        // Verbose variable names on purpose: short ones like `st`/`t` collide
        // with the players' scripting dictionaries and fail to compile.
        let script = """
        tell application "\(kind.scriptTarget)"
          set playerState to (player state as text)
          if playerState is "stopped" then return "stopped"
          set trackName to (name of current track)
          set trackArtist to (artist of current track)
          set trackArt to ""
          try
            set trackArt to (artwork url of current track)
          end try
          set trackPos to (player position as text)
          set trackDur to ((duration of current track) as text)
          return playerState & "||" & trackName & "||" & trackArtist & "||" & trackArt & "||" & trackPos & "||" & trackDur
        end tell
        """
        let outcome = await AppleScriptClient.perform(script)
        switch outcome {
        case .ok(let output):
            guard let output, let state = Self.parse(output, player: kind, at: Date()) else { return .nothing }
            return .playing(state)
        case .failed:
            return outcome.isNotPermitted ? .refused : .nothing
        }
    }

    func command(_ verb: MediaCommand) async {
        guard isRunning, let script = Self.script(verb, for: kind) else { return }
        _ = await AppleScriptClient.run(script)
    }

    /// The AppleScript one command sends, or nil when this player cannot do it.
    ///
    /// Built apart from sending it so the one line with a hazard in it can be
    /// read by a test: `swift test` cannot deliver an Apple event, but it can
    /// look at a string, and the hazard here is a decimal separator that only
    /// goes wrong on someone else's Mac.
    static func script(_ verb: MediaCommand, for kind: MediaPlayerKind) -> String? {
        switch verb {
        case .togglePlay: return #"tell application "\#(kind.scriptTarget)" to playpause"#
        case .next: return #"tell application "\#(kind.scriptTarget)" to next track"#
        case .previous: return #"tell application "\#(kind.scriptTarget)" to previous track"#
        case .seek(let seconds):
            guard kind.canSeek else { return nil }
            // `String(format:)` with no locale argument does NOT localize, so
            // the separator is a period whatever the region is set to. That
            // matters here in a way it does not on the way in: `parse` repairs a
            // comma it receives, but AppleScript will not accept one — a
            // "90,0" written into `player position` is a syntax error, and one
            // that appears only for people whose Mac is not set to English.
            let value = String(format: "%.3f", max(0, seconds))
            return #"tell application "\#(kind.scriptTarget)" to set player position to \#(value)"#
        }
    }

    // MARK: - The player's own volume

    /// Reads the player's own volume, 0–100. Both players declare
    /// `sound volume` as a read-write integer in their scripting dictionaries.
    static func volumeScript(for kind: MediaPlayerKind) -> String {
        onlyIfRunning(#"tell application "\#(kind.scriptTarget)" to get sound volume"#, kind)
    }

    /// The running check, inside the script. The caller's `isRunning` is read
    /// before the script waits its turn on the shared AppleScript queue; quit
    /// the player in that gap and a bare `tell` launches it again. `is
    /// running` sends no event, so it can never be what starts the app.
    private static func onlyIfRunning(_ statement: String, _ kind: MediaPlayerKind) -> String {
        #"if application "\#(kind.scriptTarget)" is running then "# + statement
    }

    /// Sets the player's own volume — the slider inside Spotify or Music moves
    /// with it (owner, 2026-10-01: the mixer turned the app down from outside,
    /// so the app's own slider never agreed with ours). A whole number, because
    /// the property is an integer and a "57,5" from a comma locale would not
    /// even compile.
    static func setVolumeScript(_ level: Float, for kind: MediaPlayerKind) -> String {
        let value = Int((min(max(level.isFinite ? level : 1, 0), 1) * 100).rounded())
        return onlyIfRunning(#"tell application "\#(kind.scriptTarget)" to set sound volume to \#(value)"#, kind)
    }

    /// 0–1 from what `volumeScript` returns, or nil when it is not a number.
    static func parseVolume(_ raw: String?) -> Float? {
        guard let raw,
              let value = Float(raw.trimmingCharacters(in: .whitespacesAndNewlines)
                                   .replacingOccurrences(of: ",", with: ".")),
              value.isFinite else { return nil }
        return min(max(value / 100, 0), 1)
    }

    /// Parse `state||title||artist||artworkURL||position||duration`.
    /// Spotify reports duration in MILLISECONDS, Music in seconds — normalize.
    static func parse(_ raw: String, player: MediaPlayerKind, at now: Date) -> MediaPlayerState? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != "stopped", !trimmed.isEmpty else { return nil }
        let parts = trimmed.components(separatedBy: "||")
        guard parts.count >= 6 else { return nil }

        let position = TimeInterval(parts[4].replacingOccurrences(of: ",", with: ".")) ?? 0
        var duration = TimeInterval(parts[5].replacingOccurrences(of: ",", with: ".")) ?? 0
        if player == .spotify { duration /= 1000 }

        return MediaPlayerState(
            player: player,
            isPlaying: parts[0] == "playing",
            title: parts[1],
            artist: parts[2],
            artworkURL: parts[3].isEmpty ? nil : URL(string: parts[3]),
            position: position,
            duration: duration,
            fetchedAt: now
        )
    }
}

/// `Equatable` because the model tests one case by value before dispatching
/// (the optimistic play/pause flip), which synthesis gives for free — and
/// `seek`'s payload is what makes it a command rather than a verb.
enum MediaCommand: Equatable {
    case togglePlay, next, previous
    /// Absolute seconds from the start of the track, never a delta. The player
    /// is the one that knows where it is; a relative seek computed here would
    /// race the poll it is meant to survive.
    case seek(TimeInterval)
}
