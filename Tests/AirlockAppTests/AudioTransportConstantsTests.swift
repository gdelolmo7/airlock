import AppKit
import CoreAudio
import XCTest
import AirlockCore
@testable import AirlockApp

/// The two things about `AudioOutputDevice.Transport` that Core cannot check
/// itself, both of which fail silently in the app rather than loudly in a test.
///
/// Core spells CoreAudio's four-character codes out as string literals so the
/// transport → glyph mapping stays pure with no framework behind it. That is the
/// right trade and it has one cost: a typo in a literal compiles, runs, and
/// quietly makes every device of that kind `.unknown`. This target CAN import
/// CoreAudio, so it pins each literal to Apple's own constant.
///
/// The glyph names have the identical problem from the other end: an SF Symbol
/// that does not exist is not an error, it is a blank space where the icon was.
final class AudioTransportConstantsTests: XCTestCase {
    private typealias Transport = AudioOutputDevice.Transport

    /// Every case, against the constant it claims to be. `kAudioDeviceTransport
    /// TypeContinuityCapture` is deliberately absent: Apple deprecated it in
    /// macOS 13 in favour of the wired/wireless pair, so naming it here would
    /// trade a real check for a build warning. Its code is asserted directly.
    func testEveryTransportMatchesCoreAudiosOwnConstant() {
        let pinned: [Transport: UInt32] = [
            .builtIn: kAudioDeviceTransportTypeBuiltIn,
            .aggregate: kAudioDeviceTransportTypeAggregate,
            .virtual: kAudioDeviceTransportTypeVirtual,
            .pci: kAudioDeviceTransportTypePCI,
            .usb: kAudioDeviceTransportTypeUSB,
            .fireWire: kAudioDeviceTransportTypeFireWire,
            .bluetooth: kAudioDeviceTransportTypeBluetooth,
            .bluetoothLE: kAudioDeviceTransportTypeBluetoothLE,
            .hdmi: kAudioDeviceTransportTypeHDMI,
            .displayPort: kAudioDeviceTransportTypeDisplayPort,
            .airPlay: kAudioDeviceTransportTypeAirPlay,
            .avb: kAudioDeviceTransportTypeAVB,
            .thunderbolt: kAudioDeviceTransportTypeThunderbolt,
            .continuityWired: kAudioDeviceTransportTypeContinuityCaptureWired,
            .continuityWireless: kAudioDeviceTransportTypeContinuityCaptureWireless,
        ]
        for (transport, code) in pinned {
            XCTAssertEqual(Transport(fourCharCode: code), transport,
                           "Core's literal \"\(transport.rawValue)\" no longer decodes \(code)")
        }
        // 'ccap', the deprecated Continuity code, still reported by anything on
        // an older driver.
        XCTAssertEqual(Transport(fourCharCode: 0x63_63_61_70), .continuity)
    }

    /// Nothing outside `.unknown` may map to CoreAudio's zero, or a device that
    /// simply does not answer the property would come back as a real transport.
    func testNoRealTransportDecodesTheUnknownCode() {
        XCTAssertEqual(Transport(fourCharCode: kAudioDeviceTransportTypeUnknown), .unknown)
    }

    /// Every case, and every case is covered — a transport added to the enum
    /// without a pin above would otherwise be checked by nothing.
    func testTheEnumHasNoUnpinnedCases() {
        XCTAssertEqual(Transport.allCases.count, 17,
                       "a new transport needs a line in the pin table above")
    }

    /// A glyph name that SF Symbols does not know draws nothing at all — no
    /// crash, no log anybody reads, just a hole in the island where the device
    /// icon should be. This is the only place that can catch it.
    func testEveryGlyphIsARealSFSymbol() {
        for transport in Transport.allCases {
            XCTAssertNotNil(
                NSImage(systemSymbolName: transport.symbol, accessibilityDescription: nil),
                "\(transport) draws \"\(transport.symbol)\", which SF Symbols does not have")
        }
        // The island's muted override lives outside the enum and has the same
        // failure mode.
        XCTAssertNotNil(NSImage(systemSymbolName: "speaker.slash.fill",
                                accessibilityDescription: nil))
    }
}
