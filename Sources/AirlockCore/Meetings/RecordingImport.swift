import Foundation

/// A recording somebody already has (a voice memo, a WhatsApp voice note,
/// any sound file) turned into a meeting's notes, as if the room had been
/// heard live: the same listening, the same voices, the same notes.
///
/// What is pure lives here: what the meeting is called, when it began, and
/// how far along the reading is, in the words the window and the Calls tab
/// say it in. The app does the reading (`RecordingImporter`). The file is
/// only ever read: it stays where it was, and no copy of the sound is kept
/// (`MeetingRecord.recording`).
public enum RecordingImport {
    /// Times real time the sound is played through the listening. The
    /// recogniser keeps up with several times real time, and every time in
    /// the transcript comes from the audio, so the notes come out as they
    /// would have live: a 40-minute recording takes about seven minutes.
    public static let speed: Double = 6

    /// The kinds of file offered and taken when dropped, by extension: what
    /// Voice Memos, WhatsApp, a phone or a recorder saves.
    public static let soundExtensions: Set<String> = [
        "m4a", "mp3", "wav", "aif", "aiff", "aifc", "caf", "aac", "m4b", "mp4", "mov",
        "flac", "opus", "ogg", "oga", "amr", "3gp",
    ]

    /// Whether `url` names a sound file this takes, by its extension.
    public static func isSound(_ url: URL) -> Bool {
        soundExtensions.contains(url.pathExtension.lowercased())
    }

    /// The meeting's name, from the file's: "Kitchen planning.m4a"
    /// is "Kitchen planning". Underscores read as spaces, runs of
    /// spaces as one; a file called only ".m4a" is a "Recording". The end
    /// is an extension only when it has a letter in it: "Call 12.25.03"
    /// keeps its seconds.
    public static func title(forFile name: String) -> String {
        var stem = (name as NSString).lastPathComponent
        if stem.hasPrefix("."), !stem.dropFirst().contains(".") { stem = "" }
        let ext = (stem as NSString).pathExtension
        if !ext.isEmpty, ext.count <= 5, ext.allSatisfy({ $0.isLetter || $0.isNumber }),
           ext.contains(where: \.isLetter) {
            stem = (stem as NSString).deletingPathExtension
        }
        let words = stem.replacingOccurrences(of: "_", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        return words.isEmpty ? fallbackTitle : words
    }

    public static let fallbackTitle = "Recording"

    /// When the recording began, never later than it could have, given that
    /// it has ended by `now`: its own date, which a voice memo carries; else
    /// the file's last change less its length, since a recorder writes the
    /// file to its end; else `now` less its length.
    public static func startedAt(recorded: Date?, modified: Date?, seconds: TimeInterval,
                                 now: Date) -> Date {
        let latest = now.addingTimeInterval(-max(0, seconds))
        if let recorded, recorded <= now { return min(recorded, latest) }
        if let modified, modified <= now { return min(modified.addingTimeInterval(-max(0, seconds)), latest) }
        return latest
    }

    /// How long a recording is, "40 min", or "1:30" under two minutes: the
    /// chip on a file held over the notes window.
    public static func length(_ seconds: TimeInterval) -> String {
        seconds < 120 ? MeetingFiles.clock(seconds) : "\(max(1, Int((seconds / 60).rounded()))) min"
    }

    /// What the window says when a file can't be read as sound.
    public static func unreadable(_ fileName: String) -> String {
        "Airlock can't read \u{201C}\(fileName)\u{201D} as sound. Try one saved as M4A, MP3 or WAV."
    }

    /// The four steps and where the reading is in them.
    public enum Stage: Int, Comparable, Sendable, CaseIterable {
        /// Opening the file and getting the listening ready.
        case opening
        /// Playing it through the listening: what was said, written down.
        case listening
        /// The last sentences, and the voices told apart.
        case voices
        /// The notes, written from the transcript.
        case notes

        public static func < (lhs: Stage, rhs: Stage) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    /// One line of the window's list of steps.
    public struct Step: Equatable, Sendable {
        public enum State: Equatable, Sendable { case done, now, later }
        public let text: String
        public let state: State
        /// "14 of 40 min", beside the step being done when it has a count.
        public let detail: String?
    }

    /// How far along the reading of one recording is.
    public struct Progress: Equatable, Sendable {
        public var stage: Stage
        /// The file's name, "Kitchen planning.m4a".
        public var fileName: String
        /// The recording's length, in seconds.
        public var seconds: TimeInterval
        /// How much of it has been played through the listening.
        public var heard: TimeInterval
        /// Whether the voices are told apart. Without the voice model they
        /// are not, and the step is left out.
        public var tellsVoices: Bool
        public var speed: Double

        public init(stage: Stage = .opening, fileName: String, seconds: TimeInterval,
                    heard: TimeInterval = 0, tellsVoices: Bool = true, speed: Double = RecordingImport.speed) {
            self.stage = stage
            self.fileName = fileName
            self.seconds = max(0, seconds)
            self.heard = min(max(0, heard), max(0, seconds))
            self.tellsVoices = tellsVoices
            self.speed = max(1, speed)
        }

        // MARK: How long each step is expected to take

        private var listeningTime: TimeInterval { seconds / speed }
        /// The recogniser's last sentences and the voices' last step: a few
        /// seconds, and a little more for a long recording.
        private var voicesTime: TimeInterval { 8 + seconds * (tellsVoices ? 0.012 : 0.004) }
        /// The notes: about half a minute, nearer a minute for a long one.
        private var notesTime: TimeInterval { 15 + seconds * 0.02 }
        private var total: TimeInterval { listeningTime + voicesTime + notesTime }

        /// The expected time gone by, by where the reading is.
        private var done: TimeInterval {
            switch stage {
            case .opening: 0
            case .listening: heard / speed
            case .voices: listeningTime
            case .notes: listeningTime + voicesTime
            }
        }

        /// From 0 to 1, for the bar: the share of the expected time gone
        /// by. It never says 1 before the notes are saved.
        public var fraction: Double {
            guard total > 0 else { return 0 }
            return min(0.99, max(0, done / total))
        }

        /// "35", for "35%".
        public var percent: Int { Int((fraction * 100).rounded(.down)) }

        /// Seconds the rest is expected to take.
        public var timeLeft: TimeInterval { max(0, total - done) }

        /// "About 6 minutes left.", for the window's card.
        public var timeLeftSentence: String {
            let left = timeLeft
            if stage == .notes, left < 20 { return "Almost done." }
            if left < 45 { return "Less than a minute left." }
            let minutes = Int((left / 60).rounded())
            return minutes <= 1 ? "About a minute left." : "About \(minutes) minutes left."
        }

        /// "about 6 min left", for the Calls tab's row.
        public var timeLeftShort: String {
            let left = timeLeft
            if stage == .notes, left < 20 { return "almost done" }
            if left < 45 { return "under a minute left" }
            return "about \(max(1, Int((left / 60).rounded()))) min left"
        }

        /// What it is doing, for the Calls tab: "Reading the recording",
        /// then "Telling the voices apart", then "Writing the notes".
        public var doing: String {
            switch stage {
            case .opening, .listening: "Reading the recording"
            case .voices: tellsVoices ? "Telling the voices apart" : "Reading the recording"
            case .notes: "Writing the notes"
            }
        }

        /// The window's card's heading: "Listening to the recording", then
        /// the step being done.
        public var heading: String {
            switch stage {
            case .opening, .listening: "Listening to the recording"
            case .voices, .notes: doing
            }
        }

        /// "14 of 40 min", or "0:45 of 1:30" for a recording under two
        /// minutes, where minutes would say nothing.
        public var heardWords: String {
            if seconds < 120 { return "\(MeetingFiles.clock(heard)) of \(MeetingFiles.clock(seconds))" }
            let whole = max(1, Int((seconds / 60).rounded()))
            return "\(min(whole, Int(heard / 60))) of \(whole) min"
        }

        /// The window's steps, in order: done, the one being done, then the
        /// ones still to come.
        public var steps: [Step] {
            var steps: [Step] = []
            func state(_ step: Stage) -> Step.State {
                step < stage ? .done : step == stage ? .now : .later
            }
            let quoted = "\u{201C}\(fileName)\u{201D}"
            steps.append(Step(text: stage == .opening ? "Opening \(quoted)" : "Opened \(quoted)",
                              state: state(.opening), detail: nil))
            steps.append(Step(text: "Writing down what was said", state: state(.listening),
                              detail: stage == .listening ? heardWords : nil))
            if tellsVoices {
                steps.append(Step(text: "Telling the voices apart", state: state(.voices), detail: nil))
            }
            steps.append(Step(text: "Writing the notes", state: state(.notes), detail: nil))
            return steps
        }
    }
}

extension MeetingRecord {
    /// When the meeting ended, or, for a recording still being read, when
    /// it will have: its start plus the recording's length. Nil for a call
    /// still on.
    public var shownEnd: Date? {
        endedAt ?? recording.map { startedAt.addingTimeInterval($0.seconds) }
    }
}
