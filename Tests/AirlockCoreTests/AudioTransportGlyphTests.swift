import XCTest
@testable import AirlockCore

/// The glyph for an output device comes from how it is ATTACHED, never from
/// words in its name.
///
/// The whole point of the type under test is that a device's name is a string
/// its owner can set to anything, and a substring match on it is confidently
/// wrong in both directions: rename AirPods to "Desk" and they read as
/// speakers, call a monitor "AirPods Pro Monitor" and it reads as headphones.
/// Half of these tests are therefore about names being ignored.
final class AudioTransportGlyphTests: XCTestCase {
    private typealias Transport = AudioOutputDevice.Transport

    // MARK: - Decoding CoreAudio's four-character codes

    /// `AudioTransportConstantsTests` in the app target pins these to Apple's
    /// own constants — it can import CoreAudio and Core deliberately cannot.
    /// This half only proves the decoder turns a `UInt32` into the right case.
    func testEachKnownCodeDecodesToItsTransport() {
        // 'blue', big-endian, spelled out so the arithmetic is visible once.
        XCTAssertEqual(Transport(fourCharCode: 0x62_6C_75_65), .bluetooth)
        XCTAssertEqual(Transport(fourCharCode: 0x62_6C_74_6E), .builtIn)
        for transport in Transport.allCases where transport != .unknown {
            let code = transport.rawValue.utf8.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            XCTAssertEqual(Transport(fourCharCode: code), transport,
                           "\(transport) round-trips through its own code")
        }
    }

    /// The trailing space in `'usb '` and `'pci '` is part of the code, not
    /// padding — trimming it is the obvious mistake and it silently produces
    /// `.unknown` for the two most common wired transports there are.
    func testTheTrailingSpaceInUSBAndPCIIsPartOfTheCode() {
        XCTAssertEqual(Transport(fourCharCode: 0x75_73_62_20), .usb)
        XCTAssertEqual(Transport(fourCharCode: 0x70_63_69_20), .pci)
        XCTAssertEqual(Transport.usb.rawValue, "usb ")
    }

    /// CoreAudio's literal "unknown" is zero, and a device that does not answer
    /// the property at all reads the same way. Neither may crash or invent a
    /// four-character string out of NUL bytes.
    func testZeroAndNonsenseBothLandOnUnknown() {
        XCTAssertEqual(Transport(fourCharCode: 0), .unknown)
        XCTAssertEqual(Transport(fourCharCode: 0xFF_FF_FF_FF), .unknown)
        XCTAssertEqual(Transport(fourCharCode: 0x00_01_02_03), .unknown)
        // Four printable characters that are simply not a transport we know —
        // what a future macOS adding one looks like from here.
        XCTAssertEqual(Transport(fourCharCode: 0x7A_7A_7A_7A), .unknown)
    }

    // MARK: - Transport → glyph

    func testTheTransportsThatGenuinelyNameAProductGetThatProduct() {
        XCTAssertEqual(Transport.hdmi.symbol, "tv")
        XCTAssertEqual(Transport.displayPort.symbol, "display")
        XCTAssertEqual(Transport.airPlay.symbol, "airplayaudio")
        // Built-in is the Mac itself, not a generic speaker. The product needs a
        // physical notch, so the Mac is always a laptop.
        XCTAssertEqual(Transport.builtIn.symbol, "laptopcomputer")
    }

    /// **Bluetooth is not headphones.** A Bluetooth speaker is every bit as
    /// common as Bluetooth earbuds, and the transport cannot tell them apart —
    /// so the glyph says "wireless", which is the part that is true of both.
    func testBluetoothDoesNotClaimHeadphones() {
        XCTAssertEqual(Transport.bluetooth.symbol, "wave.3.right")
        XCTAssertEqual(Transport.bluetoothLE.symbol, Transport.bluetooth.symbol,
                       "classic and LE are the same claim")
        for transport in Transport.allCases {
            XCTAssertNotEqual(transport.symbol, "headphones",
                              "nothing a transport can prove is 'these are headphones'")
        }
    }

    /// A wire that could have anything on the end of it says so, and says only
    /// that. An interface, a DAC, a headset and desk speakers are all USB.
    func testTheWiredPeripheralTransportsAgreeOnOneConnectorGlyph() {
        let wired: [Transport] = [.usb, .thunderbolt, .fireWire, .pci, .avb]
        XCTAssertEqual(Set(wired.map(\.symbol)), ["cable.connector"])
    }

    /// An unhandled or unreported transport must get a neutral glyph, never a
    /// wrong confident one — a wrong icon is worse than a vague one precisely
    /// because it gets believed.
    func testUnknownGetsTheNeutralSpeaker() {
        XCTAssertEqual(Transport.unknown.symbol, "speaker.wave.2.fill")
        XCTAssertEqual(AudioOutputDevice(uid: "u", name: "Whatever").symbol,
                       Transport.unknown.symbol,
                       "a device built without a transport is unknown, not guessed")
    }

    func testEveryTransportHasANonEmptyGlyph() {
        for transport in Transport.allCases {
            XCTAssertFalse(transport.symbol.isEmpty, "\(transport)")
        }
    }

    // MARK: - The name never decides

    /// The bug this replaces, in both directions, in one test.
    func testRenamingADeviceCannotChangeItsGlyph() {
        let airPods = AudioOutputDevice(uid: "u1", name: "AirPods Pro", transport: .bluetooth)
        let renamed = AudioOutputDevice(uid: "u1", name: "Desk", transport: .bluetooth)
        XCTAssertEqual(airPods.symbol, renamed.symbol,
                       "AirPods called 'Desk' are still attached by Bluetooth")

        // ...and a monitor that happens to have the word in its name is still a
        // monitor.
        let monitor = AudioOutputDevice(uid: "u2", name: "AirPods Pro Monitor",
                                        transport: .displayPort)
        XCTAssertEqual(monitor.symbol, "display")
        XCTAssertNotEqual(monitor.symbol, airPods.symbol)
    }

    /// Two devices on the same transport draw the same glyph however differently
    /// they are named — the property that makes this mapping a function of the
    /// device rather than of its label.
    func testTheGlyphIsAFunctionOfTheTransportAlone() {
        let names = ["MacBook Pro Speakers", "AirPods Max", "LG UltraFine Display Audio",
                     "speaker", "headphones", "", "🎧"]
        for transport in Transport.allCases {
            let glyphs = Set(names.map {
                AudioOutputDevice(uid: $0, name: $0, transport: transport).symbol
            })
            XCTAssertEqual(glyphs.count, 1, "\(transport) drew \(glyphs)")
        }
    }

    // MARK: - The island's route acknowledgement

    /// The island draws the glyph and SPEAKS the name, so the glyph is the only
    /// thing on screen saying which device sound moved to.
    func testTheRouteAcknowledgementDrawsTheDevicesOwnGlyph() {
        XCTAssertEqual(
            CompactSlot.outputRoute(name: "AirPods Pro", transport: .bluetooth,
                                    level: 0.4, muted: false).outputRouteSymbol,
            "wave.3.right")
        XCTAssertEqual(
            CompactSlot.outputRoute(name: "LG UltraFine", transport: .displayPort,
                                    level: nil, muted: false).outputRouteSymbol,
            "display")
    }

    /// Silence outranks identity: in those two seconds the thing worth saying is
    /// that sound is going nowhere, and no other glyph in the set has a slashed
    /// variant to say it with.
    func testAMutedRouteKeepsTheSlashedSpeakerWhateverItIsPluggedInto() {
        for transport in AudioOutputDevice.Transport.allCases {
            XCTAssertEqual(
                CompactSlot.outputRoute(name: "x", transport: transport,
                                        level: 0.3, muted: true).outputRouteSymbol,
                "speaker.slash.fill", "\(transport)")
        }
    }

    /// A device CoreAudio names but has not enumerated yet arrives as
    /// `.unknown`, the same beat that leaves the spoken name nil.
    func testARouteWithNoTransportYetDrawsTheNeutralGlyph() {
        XCTAssertEqual(
            CompactSlot.outputRoute(name: nil, transport: .unknown,
                                    level: 0.5, muted: false).outputRouteSymbol,
            "speaker.wave.2.fill")
    }

    func testNoOtherSlotClaimsARouteGlyph() {
        let others: [CompactSlot] = [.empty, .artwork, .wave, .meetingIcon,
                                     .shelfCount(1),
                                     .keepingAwake,
                                     .batteryCritical(minutes: 5),
                                     .agentLamp(attention: true, working: false)]
        for slot in others {
            XCTAssertNil(slot.outputRouteSymbol, "\(slot)")
        }
    }
}
