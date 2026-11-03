import Foundation

/// What "Take notes" with no call on is of: the app playing sound, if one
/// is, else the room. A webinar you only listen to plays sound and never
/// takes the microphone, so the call detector never sees it; its sound,
/// taken straight from the app, is the meeting. Pure, so the choice is
/// tested; the app hands in which apps are playing, music apps and
/// Airlock already left out (`NeverACall`).
public enum HandNotesSource {
    public struct Player: Equatable, Sendable {
        public var bundleID: String
        public var name: String

        public init(bundleID: String, name: String) {
            self.bundleID = bundleID
            self.name = name
        }
    }

    /// The app to take notes of, or nil for the room. The app in front
    /// first, since that is the one being watched; else, of several, the
    /// first by name, so the same sound always gives the same answer.
    public static func app(playing: [Player], frontmost: String?) -> Player? {
        if let frontmost, let front = playing.first(where: { $0.bundleID == frontmost }) {
            return front
        }
        return playing.min { ($0.name, $0.bundleID) < ($1.name, $1.bundleID) }
    }
}
