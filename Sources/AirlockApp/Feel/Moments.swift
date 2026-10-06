import AirlockCore
import Foundation
import os

/// The one place a moment is announced (card A3). Sound, haptics and motion
/// register here and react; the code where the thing happened only says that
/// it did.
///
/// Every admitted moment is logged, so "did the gate sound not play, or did
/// the gate never arrive?" is one `log show` away:
///
///     /usr/bin/log show --last 10m --predicate 'subsystem == "com.airlock.app" && category == "moment"'
///
/// The detail is for telling two of a kind apart — a tab name, a reason, a
/// count. Never content: no clipboard text, no command, no file name, no
/// question.
@MainActor
final class Moments {
    static let shared = Moments()

    private static let log = Logger(subsystem: "com.airlock.app", category: "moment")

    private var dedupe = MomentDedupe()
    private var listeners: [Moment: [() -> Void]] = [:]

    func listen(to moment: Moment, _ react: @escaping () -> Void) {
        listeners[moment, default: []].append(react)
    }

    func announce(_ moment: Moment, _ detail: String? = nil, now: Date = Date()) {
        guard dedupe.admit(moment, at: now) else {
            Self.log.debug("\(moment.row, privacy: .public) \(moment.rawValue, privacy: .public) again within \(MomentDedupe.window)s — once")
            return
        }
        Self.log.notice("\(moment.row, privacy: .public) \(moment.rawValue, privacy: .public)\(detail.map { " · " + $0 } ?? "", privacy: .public)")
        for react in listeners[moment] ?? [] { react() }
    }
}
