import XCTest
@testable import AirlockCore

/// The Wi-Fi strip used to read "Wi-Fi is on" under a button that is lit when
/// Wi-Fi is on. These are the sentences that earn the space instead.
final class NetworkStatusTests: XCTestCase {
    private func status(_ link: NetworkStatus.Link, satisfied: Bool = true,
                        expensive: Bool = false, constrained: Bool = false) -> NetworkStatus {
        NetworkStatus(link: link, isSatisfied: satisfied,
                      isExpensive: expensive, isConstrained: constrained)
    }

    /// THE case the type exists for: the radio is on, the menu bar shows bars,
    /// and nothing is reachable. A captive portal, or a router with no uplink.
    /// Outwardly identical to "Wi-Fi is off"; opposite thing to do about it.
    func testRadioOnWithNoRouteIsDistinctFromRadioOff() {
        let dead = status(.none, satisfied: false)
        XCTAssertEqual(dead.line(radioOn: true), "Wi-Fi is on, but nothing is reachable")
        XCTAssertEqual(dead.line(radioOn: false), "Wi-Fi is off")
        XCTAssertNotEqual(dead.line(radioOn: true), dead.line(radioOn: false))
        XCTAssertEqual(dead.symbol(radioOn: true), "wifi.exclamationmark")
        XCTAssertEqual(dead.symbol(radioOn: false), "wifi.slash")
    }

    /// A personal hotspot arrives as Wi-Fi AND expensive. Saying so before a
    /// build pulls a gigabyte of dependencies is the whole point.
    func testHotspotIsNamedRatherThanCalledWiFi() {
        let tethered = status(.wifi, expensive: true)
        XCTAssertEqual(tethered.line(radioOn: true), "Personal hotspot · metered")
        XCTAssertEqual(tethered.symbol(radioOn: true), "personalhotspot")
        XCTAssertEqual(status(.wifi).line(radioOn: true), "Wi-Fi")
    }

    /// Ethernet with the radio still on: the traffic is not going where the lit
    /// Wi-Fi button implies, which is worth one clause.
    func testWiredWhileTheRadioIsOnSaysSo() {
        XCTAssertEqual(status(.wired).line(radioOn: true), "Ethernet · Wi-Fi on but unused")
        XCTAssertEqual(status(.wired).line(radioOn: false), "Ethernet")
    }

    /// Cost outranks speed — it is the one that changes what somebody does next.
    func testMeteredIsStatedBeforeLowDataMode() {
        let both = status(.wifi, expensive: true, constrained: true)
        let line = both.line(radioOn: true)
        XCTAssertTrue(line.contains("metered"))
        XCTAssertTrue(line.contains("Low Data Mode"))
        XCTAssertLessThan(line.range(of: "metered")!.lowerBound,
                          line.range(of: "Low Data Mode")!.lowerBound)
    }

    /// The first path lands a beat after the panel opens. Reporting an outage
    /// for those milliseconds, every single time, is worse than waiting.
    func testUnresolvedSaysCheckingRatherThanDown() {
        XCTAssertEqual(NetworkStatus.unknown.line(radioOn: true, hasResolved: false), "Checking…")
        XCTAssertEqual(NetworkStatus.unknown.symbol(radioOn: true, hasResolved: false), "wifi",
                       "and it must not flash the alarm glyph either")
    }

    // MARK: - Signal

    /// Bands from dBm, which is negative and better nearer zero. The desk this
    /// was written at reads −40.
    func testRSSIBands() {
        XCTAssertEqual(NetworkStatus.Signal(rssi: -40), .strong)
        XCTAssertEqual(NetworkStatus.Signal(rssi: -55), .strong)
        XCTAssertEqual(NetworkStatus.Signal(rssi: -60), .fair)
        XCTAssertEqual(NetworkStatus.Signal(rssi: -75), .weak)
    }

    /// Printed only when it is bad. A strip that says "strong" every day is one
    /// nobody reads on the day it matters.
    func testOnlyAWeakSignalIsMentioned() {
        func line(_ s: NetworkStatus.Signal) -> String {
            NetworkStatus(link: .wifi, isSatisfied: true, isExpensive: false,
                          isConstrained: false, signal: s).line(radioOn: true)
        }
        XCTAssertEqual(line(.strong), "Wi-Fi")
        XCTAssertEqual(line(.fair), "Wi-Fi")
        XCTAssertEqual(line(.weak), "Wi-Fi · weak signal")
    }

    /// Off Wi-Fi there is no signal to report, and inventing one would be worse
    /// than the silence.
    func testSignalDefaultsToNilAndSaysNothing() {
        XCTAssertNil(status(.wired).signal)
        XCTAssertEqual(status(.wired).line(radioOn: false), "Ethernet")
    }

    /// A VPN or virtual interface is `other`. "Connected" is actionable where
    /// "other" is merely accurate.
    func testAnUnnamedInterfaceStillReadsAsConnected() {
        XCTAssertEqual(status(.other).line(radioOn: true), "Connected")
    }
}
