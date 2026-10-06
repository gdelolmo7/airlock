import Foundation

/// A microphone you could dictate into.
public struct AudioInputDevice: Equatable, Sendable, Identifiable {
    /// Stable across reboots and replugs, unlike the numeric `AudioDeviceID`,
    /// which the system reassigns freely. This is what gets persisted — saving
    /// the numeric id would silently point at a different device after a
    /// restart, which is the worst kind of wrong: plausible and unnoticed.
    public let uid: String
    public let name: String
    public let channels: Int

    public var id: String { uid }

    public init(uid: String, name: String, channels: Int) {
        self.uid = uid
        self.name = name
        self.channels = channels
    }
}

/// Which microphone to actually use, given what the user asked for and what is
/// currently plugged in.
///
/// The interesting case is absence. A saved device is a preference, not a
/// promise: pick AirPods, walk away from them, and the preference now names
/// something that does not exist. Failing would be wrong — you can still
/// dictate — and silently using another microphone would be worse, because the
/// symptom is a transcript that is subtly bad for reasons nothing explains.
/// So it falls back and says so.
public enum AudioInputSelection {
    public enum Resolution: Equatable, Sendable {
        /// No preference expressed — follow whatever macOS is using.
        case systemDefault
        case device(AudioInputDevice)
        /// A device was chosen and is not here. Using the system default; the
        /// UI is expected to say which device is missing.
        case unavailable(uid: String)

        /// The device to route to, or nil to leave the engine on the default.
        public var device: AudioInputDevice? {
            if case .device(let device) = self { return device }
            return nil
        }
    }

    public static func resolve(preferredUID: String,
                               available: [AudioInputDevice]) -> Resolution {
        let wanted = preferredUID.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return .systemDefault }
        if let match = available.first(where: { $0.uid == wanted }) { return .device(match) }
        return .unavailable(uid: wanted)
    }
}
