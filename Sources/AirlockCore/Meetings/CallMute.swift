import Foundation

/// Whether you are muted in the call, read from the call app's own mute
/// button.
///
/// The microphone hears you whether or not the call does: Meet, Zoom and
/// Teams all keep it open while muted, so they can say "you're muted" when
/// you talk. Nothing in Core Audio tells the two apart, so the button is the
/// only honest source. Its label names what pressing it would DO, so
/// "Turn on microphone" means you are muted now.
///
/// Matched whole, never as a prefix, so "Mute all" or "Mute Ana's
/// microphone" (a host's buttons for other people) never read as yours.
/// English and Spanish for now: the owner's two languages. A label in
/// another language reads as nothing, which is today's behaviour, not a
/// wrong answer.
public enum CallMuteLabels {
    public enum Family: Equatable, Sendable {
        /// A call in a browser tab: microphone wording only, because a
        /// video's bare "Mute" button can sit on the same page.
        case browser
        /// A call app of its own (Zoom, Teams, FaceTime, Slack): its plain
        /// "Mute" and "Unmute" too.
        case app
    }

    /// True for muted, false for unmuted, nil for a label that says neither.
    ///
    /// `checked` is the element's on/off state when it is a switch rather
    /// than a button. A switch keeps one label, so a ticked "Mute" means
    /// muted. Only the "Mute" wording reads it that way: an "Unmute" whose
    /// label flips is a button, whatever extra state an app hangs on it.
    public static func isMuted(label: String, checked: Bool? = nil, in family: Family) -> Bool? {
        let key = normalized(label)
        let wouldUnmute = micMuted.contains(key) || (family == .app && appMuted.contains(key))
        let wouldMute = micUnmuted.contains(key) || (family == .app && appUnmuted.contains(key))
        if wouldUnmute { return true }
        if wouldMute { return checked ?? false }
        return nil
    }

    /// Meet's microphone button, whatever language it is in: its label ends
    /// with the shortcut that toggles it, "(⌘ + d)". Used to say in the log
    /// that the button was there but its wording is unknown, which is the
    /// one fix this needs for a new language.
    public static func looksLikeMeetMicButton(_ label: String) -> Bool {
        let compact = label.lowercased().filter { !$0.isWhitespace }
        return ["(⌘+d)", "(cmd+d)", "(ctrl+d)", "(control+d)"].contains { compact.hasSuffix($0) }
    }

    /// Lower case, accents folded, the keyboard shortcut in brackets and any
    /// closing full stop dropped, spaces collapsed.
    static func normalized(_ label: String) -> String {
        var text = label.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        while let open = text.lastIndex(of: "("), text[open...].contains(")") {
            text = String(text[..<open])
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".,:")))
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    // Pressing it would turn the microphone ON: you are muted.
    private static let micMuted: Set<String> = [
        "turn on microphone", "turn on mic", "unmute microphone", "unmute mic",
        "activar microfono", "activar el microfono", "reactivar microfono",
        "reactivar el microfono", "activar mic",
    ]
    // Pressing it would turn the microphone OFF: you are heard.
    private static let micUnmuted: Set<String> = [
        "turn off microphone", "turn off mic", "mute microphone", "mute mic",
        "desactivar microfono", "desactivar el microfono", "silenciar microfono",
        "silenciar el microfono", "desactivar mic",
    ]
    private static let appMuted: Set<String> = [
        "unmute", "unmute audio", "unmute my audio", "unmute myself",
        "reactivar audio", "activar audio", "dejar de silenciar", "cancelar silencio",
        "anular silencio",
    ]
    private static let appUnmuted: Set<String> = [
        "mute", "mute audio", "mute my audio", "mute myself",
        "silenciar", "silenciar audio", "desactivar audio", "silenciarme",
    ]
}

/// When you were muted during a call, as the button was seen to say.
///
/// The microphone's sound reaches the transcriber a second late, and each
/// piece is checked against this before it goes: muted, it goes as
/// silence. The second is what makes a mute count from the moment it was
/// pressed rather than the moment it was next looked at.
///
/// **A mute is dated back, an unmute is not.** The button is looked at a few
/// times a second, so a change happened somewhere since the previous look.
/// A mute starts at that previous look and an unmute ends at the look that
/// saw it: when unsure, a word is dropped rather than written down.
///
/// A look that could not read the button (the Meet tab behind another, the
/// app busy) keeps whatever was last seen.
public struct MuteTimeline: Equatable, Sendable {
    public struct Stretch: Equatable, Sendable {
        public var start: Date
        /// Nil while still muted.
        public var end: Date?
    }

    public private(set) var stretches: [Stretch] = []
    private var lastLook: Date?

    public init() {}

    /// Muted right now, as far as anyone knows.
    public var isMuted: Bool { stretches.last.map { $0.end == nil } ?? false }

    /// One look at the button: true muted, false unmuted, nil unreadable.
    public mutating func observe(_ muted: Bool?, at date: Date) {
        defer { lastLook = date }
        switch muted {
        case true? where !isMuted:
            stretches.append(Stretch(start: min(lastLook ?? date, date), end: nil))
        case false? where isMuted:
            stretches[stretches.count - 1].end = date
        default:
            break
        }
    }

    public func isMuted(at date: Date) -> Bool {
        stretches.contains { $0.start <= date && ($0.end.map { date < $0 } ?? true) }
    }

    /// Stretches that ended before `date` can no longer silence anything.
    public mutating func forget(before date: Date) {
        stretches.removeAll { $0.end.map { $0 < date } ?? false }
    }
}
