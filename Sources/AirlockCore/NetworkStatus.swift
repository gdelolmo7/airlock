import Foundation

/// What the connection actually is, as one line the Wi-Fi strip can print.
///
/// **The strip it replaces disclosed nothing.** It read "Wi-Fi is on" / "Wi-Fi
/// is off" under a button that is lit when Wi-Fi is on and dark when it is not
/// — a disclosure that repeats the control above it. What a person cannot see
/// from the rail is where the route actually goes, and the two cases worth the
/// space are the ones macOS hides behind a menu: **a radio that is on with no
/// route behind it**, and **a link that costs money**.
///
/// Pure, and time- and framework-free: `NWPath` is reduced to these four facts
/// at the boundary, so every sentence below can be read in a test instead of by
/// unplugging an Ethernet cable and tethering a phone.
public struct NetworkStatus: Equatable, Sendable {

    /// Which interface carries the route. `none` when nothing does.
    public enum Link: String, Equatable, Sendable {
        case wifi, wired, cellular, other, none
    }

    /// How good the Wi-Fi link is, when there is one.
    ///
    /// From RSSI, which — unlike the network's NAME — costs no Location prompt.
    /// Verified on the machine rather than assumed: `ssid()` returns nil without
    /// Location authorization while `rssiValue()` and `transmitRate()` answer
    /// fine, so the strip can say how good the connection is without asking for
    /// permission to know where you are.
    public enum Signal: Equatable, Sendable {
        case strong, fair, weak

        /// dBm bands. Negative, and closer to zero is better: a healthy desk is
        /// around −40, a far room −70, and below −80 nothing completes.
        public init(rssi: Int) {
            switch rssi {
            case (-55)...: self = .strong
            case (-70)..<(-55): self = .fair
            default: self = .weak
            }
        }
    }

    public let link: Link
    /// A route exists. False is not "slow" — it is nothing at all.
    public let isSatisfied: Bool
    /// Metered. On a Mac this is almost always a phone: a personal hotspot over
    /// Wi-Fi arrives as `.wifi` AND expensive, which is exactly the pair worth
    /// saying out loud before a `swift build` pulls a gigabyte of dependencies.
    public let isExpensive: Bool
    /// Low Data Mode is on for this interface.
    public let isConstrained: Bool
    /// Nil off Wi-Fi, or before the first reading.
    public let signal: Signal?

    public init(link: Link, isSatisfied: Bool, isExpensive: Bool, isConstrained: Bool,
                signal: Signal? = nil) {
        self.link = link
        self.isSatisfied = isSatisfied
        self.isExpensive = isExpensive
        self.isConstrained = isConstrained
        self.signal = signal
    }

    /// Nothing known yet — the monitor has not delivered its first path.
    ///
    /// Drawn as "checking" rather than as "no connection", because the first
    /// update lands a beat after the panel opens and a panel that says the
    /// network is down for 200ms every time is worse than one that waits.
    public static let unknown = NetworkStatus(link: .none, isSatisfied: false,
                                              isExpensive: false, isConstrained: false)

    /// - Parameter radioOn: the Wi-Fi power state, which the rail already knows
    ///   and `NWPath` does not report. It is what separates "Wi-Fi is off" from
    ///   "Wi-Fi is on and getting nowhere" — the same outward silence, opposite
    ///   things to do about it.
    public func line(radioOn: Bool, hasResolved: Bool = true) -> String {
        guard hasResolved else { return "Checking…" }

        guard isSatisfied else {
            if !radioOn { return "Wi-Fi is off" }
            // The case this whole type exists for. The chip is lit, the menu bar
            // shows bars, and nothing works — a captive portal, a router with no
            // uplink, a network you joined but never signed in to.
            return "Wi-Fi is on, but nothing is reachable"
        }

        var parts = [name]
        // Ordered by what changes a decision. "Costs money" outranks "is slow".
        if isExpensive { parts.append("metered") }
        if isConstrained { parts.append("Low Data Mode") }
        // Wired while the radio is still on is worth stating: the traffic is not
        // going where the lit Wi-Fi button implies.
        if link == .wired, radioOn { parts.append("Wi-Fi on but unused") }
        // Only when it is bad. A strip that prints "strong" every day is one
        // nobody reads on the day it says "weak" — and the number is always
        // fine, right up until it is the answer to "why is this slow".
        if signal == .weak { parts.append("weak signal") }
        return parts.joined(separator: " · ")
    }

    /// SF Symbol for the strip's glyph.
    public func symbol(radioOn: Bool, hasResolved: Bool = true) -> String {
        guard hasResolved else { return "wifi" }
        guard isSatisfied else { return radioOn ? "wifi.exclamationmark" : "wifi.slash" }
        switch link {
        case .wired: return "cable.connector"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wifi: return isExpensive ? "personalhotspot" : "wifi"
        case .other, .none: return "globe"
        }
    }

    private var name: String {
        switch link {
        case .wifi: return isExpensive ? "Personal hotspot" : "Wi-Fi"
        case .wired: return "Ethernet"
        case .cellular: return "Cellular"
        // A VPN or a virtual interface. Naming it "other" would be honest and
        // useless; "Connected" is what the user can act on.
        case .other, .none: return "Connected"
        }
    }
}
