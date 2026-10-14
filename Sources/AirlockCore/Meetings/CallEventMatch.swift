import Foundation

/// Which calendar event, if any, a call that just started belongs to.
///
/// The notes are named after the meeting and, on a call with one other
/// person, call that person by name. Both are only worth doing when the match
/// is near certain: a wrong meeting name on somebody's notes is worse than
/// "Call in Zoom". So the rule is narrow on purpose. The event has to be a
/// real meeting (not an all-day reminder), start close to when the call did,
/// and look like a call: a joinable link, or at least two people invited.
public enum CallEventMatch {
    /// One calendar event, reduced to what the match needs. The App fills it
    /// from EventKit; everything after that is decided here, where it can be
    /// tested.
    public struct Candidate: Equatable, Sendable {
        public var title: String
        public var start: Date
        public var end: Date
        public var isAllDay: Bool
        /// The meeting service the event's link points at, if it has one.
        public var link: MeetingLink.Provider?
        /// Everybody on the invite, you and meeting rooms included.
        public var invited: Int
        /// The other people's display names, never you, never a room.
        public var others: [String]

        public init(title: String, start: Date, end: Date, isAllDay: Bool = false,
                    link: MeetingLink.Provider? = nil, invited: Int = 0, others: [String] = []) {
            self.title = title
            self.start = start
            self.end = end
            self.isAllDay = isAllDay
            self.link = link
            self.invited = invited
            self.others = others
        }
    }

    /// How far a meeting's start may be from the call's, either side. People
    /// join a few minutes early or late; a quarter of an hour covers that
    /// without reaching the meeting before or after.
    public static let reach: TimeInterval = 15 * 60

    /// The event the call belongs to, or nil when none clearly does.
    ///
    /// When several fit, one whose link is for the same service as the call
    /// wins (a Zoom call is the Zoom meeting, not the Teams one beside it),
    /// then the one that starts nearest the call.
    public static func pick(_ candidates: [Candidate], callStart: Date,
                            site: MeetingLink.Provider?) -> MeetingEvent? {
        let fitting = candidates.filter { candidate in
            !candidate.isAllDay
                && abs(candidate.start.timeIntervalSince(callStart)) <= reach
                && (candidate.link != nil || candidate.invited >= 2)
        }
        let best = fitting.enumerated().min { lhs, rhs in
            let left = rank(lhs.element, callStart: callStart, site: site)
            let right = rank(rhs.element, callStart: callStart, site: site)
            return (left.sameSite, left.distance, lhs.offset) < (right.sameSite, right.distance, rhs.offset)
        }?.element
        return best.map { MeetingEvent(title: $0.title, start: $0.start, attendees: $0.others) }
    }

    /// Lower is better: 0 when the link is the call's own service.
    private static func rank(_ candidate: Candidate, callStart: Date,
                             site: MeetingLink.Provider?) -> (sameSite: Int, distance: TimeInterval) {
        let sameSite = site != nil && candidate.link == site ? 0 : 1
        return (sameSite, abs(candidate.start.timeIntervalSince(callStart)))
    }

    /// A name fit to show for an attendee, or nil. Calendars often have only
    /// an address for somebody outside the organisation; an address is not a
    /// name, and printing one in the notes reads like a mistake.
    public static func displayName(_ raw: String?) -> String? {
        guard let name = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty, !name.contains("@") else { return nil }
        return name
    }

    /// The meeting service a desktop call app is, when it is one. A call in
    /// the Zoom app has no web page to read the service from, but it is just
    /// as surely a Zoom meeting, and that is what picks between two events.
    public static func provider(ofApp bundleID: String) -> MeetingLink.Provider? {
        switch bundleID {
        case "us.zoom.xos": .zoom
        case "com.microsoft.teams2", "com.microsoft.teams": .teams
        case "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp": .webex
        case "com.hnc.Discord": .discord
        default: nil
        }
    }
}
