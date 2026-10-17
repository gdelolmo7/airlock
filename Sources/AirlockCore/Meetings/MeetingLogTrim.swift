import Foundation

/// How `meetings.log` stays small without losing the start of a long call.
///
/// The log used to be deleted once it passed its cap and started over. A
/// call writes two lines a minute for as long as it lasts (the `echo:` and
/// `sides:` check-ups), so a 2 h 40 call filled the cap on its own: by its
/// end the file had been started over and its first hour was gone. That hour
/// held the lines a call that went wrong is read for: which call app it was,
/// whether the mute button was found, the first echo delay.
///
/// So the log is cut back instead, dropping lines in this order, oldest
/// first within each:
/// 1. the every-minute check-ups outside a call's opening;
/// 2. every other line outside a call's opening;
/// 3. the openings themselves: the first `openingLines` lines from each
///    `call started:` or `notes: new` line.
///
/// A 3-hour call keeps its opening, every line that says something happened,
/// its end, and as many recent check-ups as fit. The file never passes
/// `cap`. The prefixes are the ones `MeetingNotesModel` writes; a line whose
/// wording changes only loses its place in the order, never the cap.
public enum MeetingLogTrim {
    /// Past this size the log is cut back: the same ceiling as the app's
    /// other logs.
    public static let cap = 64 * 1024
    /// What a cut leaves at most, so the next one is about forty minutes of
    /// call away rather than at the next line.
    public static let keep = 48 * 1024
    /// How many lines from a call's start count as its opening: about the
    /// first ten minutes of a busy call.
    public static let openingLines = 60
    /// The first line of a log that has been cut, so a gap reads as a cut
    /// and not as a silence.
    public static let cutNote =
        "(lines left out to keep this file small: every-minute check-ups first, a call's first lines last)"

    /// Where a call, or notes taken by hand, start.
    static let openers = ["call started: ", "notes: new "]
    /// The check-ups written once a minute for as long as notes listen.
    static let everyMinute = ["echo: delay ", "echo: no delay found", "sides: "]

    /// `text` cut back to at most `keep` bytes, its lines in their order,
    /// under `cutNote`. A text already that small comes back as it is.
    public static func trimmed(_ text: String, keep: Int = MeetingLogTrim.keep) -> String {
        var lines = text.split(separator: "\n")
        if lines.first == Substring(cutNote) { lines.removeFirst() }
        let sizes = lines.map { $0.utf8.count + 1 }
        var total = sizes.reduce(0, +)
        guard total > keep else { return text }
        total += cutNote.utf8.count + 1

        var opening = [Bool](repeating: false, count: lines.count)
        for (index, line) in lines.enumerated() where starts(line, with: openers) {
            for inOpening in index..<min(index + openingLines, lines.count) { opening[inOpening] = true }
        }
        let rank = lines.indices.map { index in
            opening[index] ? 2 : starts(lines[index], with: everyMinute) ? 0 : 1
        }
        let order = lines.indices.sorted { (rank[$0], $0) < (rank[$1], $1) }

        var dropped = [Bool](repeating: false, count: lines.count)
        for index in order {
            guard total > keep else { break }
            dropped[index] = true
            total -= sizes[index]
        }
        let kept = lines.indices.filter { !dropped[$0] }.map { lines[$0] }
        return ([Substring(cutNote)] + kept).joined(separator: "\n") + "\n"
    }

    /// Cuts the log at `url` back to `keep` once it is past `cap`. Written
    /// in place, so the file keeps its owner-only permissions; one that
    /// cannot be read or written is started over, as every log here is.
    public static func trimIfNeeded(at url: URL, cap: Int = MeetingLogTrim.cap, keep: Int = MeetingLogTrim.keep) {
        let manager = FileManager.default
        guard let size = (try? manager.attributesOfItem(atPath: url.path)[.size]) as? Int,
              size > cap else { return }
        do {
            let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data(trimmed(text, keep: keep).utf8))
        } catch {
            try? manager.removeItem(at: url)
        }
    }

    /// Whether a `<time>  <message>` line's message starts with one of
    /// `prefixes`. The time is the first thing before two spaces, whatever
    /// the Mac's clock format.
    static func starts(_ line: Substring, with prefixes: [String]) -> Bool {
        guard let gap = line.range(of: "  ") else { return false }
        let message = line[gap.upperBound...]
        return prefixes.contains { message.hasPrefix($0) }
    }
}
