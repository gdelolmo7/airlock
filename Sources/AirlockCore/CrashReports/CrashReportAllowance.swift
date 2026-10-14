import Foundation
import os

/// How many crash reports one Mac may send in a day.
///
/// Airlock's reports share a monthly allowance at Sentry with another app,
/// and Sentry's free plan has no cap of its own for one of them. A Mac that
/// crashes at every launch, or an app that keeps hanging, would otherwise
/// send a report every time; five a day say as much about the fault and
/// leave the allowance for everybody else.
///
/// Counted per calendar day in the preferences, so the count survives the
/// crash that produced it. Safe from any thread: Sentry asks from whichever
/// one is sending. It keeps the preferences' name rather than the
/// preferences, which the compiler cannot check across threads.
public final class CrashReportAllowance: Sendable {
    public static let perDay = 5
    public static let dayKey = "crashReports.sentDay"
    public static let countKey = "crashReports.sentCount"

    /// `nil` for the app's own preferences.
    private let suiteName: String?
    private let limit: Int
    private let lock = OSAllocatedUnfairLock()

    public init(suiteName: String? = nil, limit: Int = CrashReportAllowance.perDay) {
        self.suiteName = suiteName
        self.limit = limit
    }

    /// Takes one report from the day's allowance.
    /// - Returns: whether there was one left.
    public func take(on date: Date = Date()) -> Bool {
        let day = Self.day(of: date)
        return lock.withLock {
            let defaults = suiteName.flatMap(UserDefaults.init(suiteName:)) ?? .standard
            let used = defaults.string(forKey: Self.dayKey) == day ? defaults.integer(forKey: Self.countKey) : 0
            guard used < limit else { return false }
            defaults.set(day, forKey: Self.dayKey)
            defaults.set(used + 1, forKey: Self.countKey)
            return true
        }
    }

    /// The Mac's own calendar day, as `2026-10-09`.
    private static func day(of date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
