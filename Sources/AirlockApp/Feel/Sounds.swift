import AirlockCore
import AppKit
import AudioToolbox
import os
import SwiftUI

/// The four sounds at their moments (card D2): every moment `Moment.sound`
/// names plays here, behind the one Sounds setting, and nowhere else.
///
/// Played as system sounds rather than with `NSSound`, so they follow the
/// Mac's alert volume and its "Play sound effects through" output — the
/// slider people already use to quiet their Mac's beeps quiets these too.
///
/// Every decision is logged, never content:
///
///     /usr/bin/log show --last 10m --predicate 'subsystem == "com.airlock.app" && category == "sound"'
@MainActor
final class Sounds {
    static let levelKey = "feel.sounds"
    /// The gate sound's old switch, read once so its answer carries over.
    static let legacyKey = "agents.gateSound"
    /// The first choice in the gate sound picker: Airlock's own Needs you.
    static let airlockChoice = "Airlock"

    /// Settings › General › Sounds. Only important unless somebody turned
    /// the old gate sound off, in which case Off (`SoundLevel.resolve`).
    static var level: SoundLevel {
        get {
            let defaults = UserDefaults.standard
            return SoundLevel.resolve(stored: defaults.string(forKey: levelKey),
                                      legacyGateSound: defaults.object(forKey: legacyKey) as? Bool)
        }
        set { Defaults.set(newValue.rawValue, levelKey) }
    }

    private static let log = Logger(subsystem: "com.airlock.app", category: "sound")

    /// The level as Settings edits it, over an `@AppStorage(levelKey)`
    /// string, so the General picker and the Agents switch stay in step.
    static func binding(_ stored: Binding<String?>) -> Binding<SoundLevel> {
        Binding(get: {
            SoundLevel.resolve(stored: stored.wrappedValue,
                               legacyGateSound: UserDefaults.standard.object(forKey: legacyKey) as? Bool)
        }, set: { stored.wrappedValue = $0.rawValue })
    }

    private let currentLevel: @MainActor () -> SoundLevel
    private let needsYouChoice: @MainActor () -> String
    private let clock: @MainActor () -> Date
    private let length: @MainActor (String) -> TimeInterval
    private let play: @MainActor (String) -> Void
    private let later: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private var overlap = SoundOverlap()
    /// Bumped by every sound that plays or waits, so a waiting one that has
    /// been replaced finds out when its turn comes.
    private var turn = 0

    /// Everything but `moments` and `needsYouChoice` is there for the tests,
    /// which must neither write a real preference nor make a noise.
    init(listeningTo moments: Moments = .shared,
         level: @escaping @MainActor () -> SoundLevel = { Sounds.level },
         needsYouChoice: @escaping @MainActor () -> String,
         clock: @escaping @MainActor () -> Date = { Date() },
         length: @escaping @MainActor (String) -> TimeInterval = Sounds.length,
         play: @escaping @MainActor (String) -> Void = Sounds.play,
         later: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void = Sounds.later) {
        self.currentLevel = level
        self.needsYouChoice = needsYouChoice
        self.clock = clock
        self.length = length
        self.play = play
        self.later = later
        for moment in Moment.allCases {
            guard let sound = moment.sound else { continue }
            moments.listen(to: moment) { [weak self] in self?.react(to: sound) }
        }
    }

    /// The file a sound plays: its own, or for Needs you the Mac sound picked
    /// in Settings › Agents.
    static func name(for sound: AirlockSound, needsYouChoice: String) -> String {
        guard sound == .needsYou, needsYouChoice != airlockChoice else { return sound.resourceName }
        return needsYouChoice
    }

    private func react(to sound: AirlockSound) {
        let level = currentLevel()
        guard level.plays(sound) else {
            Self.log.debug("\(sound.rawValue, privacy: .public) silent at \(level.rawValue, privacy: .public)")
            return
        }
        let name = Self.name(for: sound, needsYouChoice: needsYouChoice())
        let now = clock()
        switch overlap.admit(sound, length: length(name), at: now) {
        case .now:
            turn += 1
            Self.log.notice("\(sound.rawValue, privacy: .public) played · \(name, privacy: .public)")
            play(name)
        case .at(let start):
            turn += 1
            let mine = turn
            let wait = max(0, start.timeIntervalSince(now))
            Self.log.notice("\(sound.rawValue, privacy: .public) waits \(wait, format: .fixed(precision: 2))s for the one playing")
            later(wait) { [weak self] in
                guard let self, self.turn == mine else { return }
                Self.log.notice("\(sound.rawValue, privacy: .public) played after waiting · \(name, privacy: .public)")
                self.play(name)
            }
        case .skip:
            Self.log.notice("\(sound.rawValue, privacy: .public) skipped under a more important sound")
        }
    }

    // MARK: Playing

    /// Created once per file and kept: a handful of short sounds, and
    /// disposing one that is still playing is not documented to be safe.
    private static var loaded: [String: SystemSoundID] = [:]
    private static var lengths: [String: TimeInterval] = [:]

    /// Airlock's own sounds sit flat in the app's resources; the gate
    /// picker's Mac sounds in the system's folder.
    static func url(for name: String) -> URL? {
        if let own = Bundle.main.url(forResource: name, withExtension: "wav") { return own }
        let system = URL(fileURLWithPath: "/System/Library/Sounds/\(name).aiff")
        return FileManager.default.fileExists(atPath: system.path) ? system : nil
    }

    static func play(_ name: String) {
        if let id = loaded[name] {
            AudioServicesPlaySystemSoundWithCompletion(id, nil)
            return
        }
        guard let url = url(for: name) else {
            log.error("no sound file for \(name, privacy: .public)")
            return
        }
        var id: SystemSoundID = 0
        let status = AudioServicesCreateSystemSoundID(url as CFURL, &id)
        guard status == noErr else {
            log.error("could not load \(name, privacy: .public): \(status)")
            return
        }
        loaded[name] = id
        AudioServicesPlaySystemSoundWithCompletion(id, nil)
    }

    /// How long a file plays, so the next sound knows when it may start. A
    /// file that cannot be read is treated as half a second.
    static func length(_ name: String) -> TimeInterval {
        if let known = lengths[name] { return known }
        let measured = url(for: name).flatMap { NSSound(contentsOf: $0, byReference: true)?.duration } ?? 0.5
        lengths[name] = measured
        return measured
    }

    private static func later(_ delay: TimeInterval, _ action: @escaping @MainActor () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            action()
        }
    }
}
