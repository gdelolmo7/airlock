import XCTest
@testable import AirlockCore

/// A saved microphone is a preference, not a promise. The interesting cases are
/// all about absence: pick AirPods, walk away from them, and the preference now
/// names something that is not there.
final class AudioInputSelectionTests: XCTestCase {
    private let builtIn = AudioInputDevice(uid: "BuiltInMicrophoneDevice",
                                           name: "MacBook Pro Microphone", channels: 1)
    private let airpods = AudioInputDevice(uid: "AirPods-1234", name: "AirPods Pro", channels: 1)

    func testNoPreferenceFollowsTheSystem() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "", available: [builtIn]),
                       .systemDefault)
    }

    func testBlankPreferenceIsAlsoNoPreference() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "   ", available: [builtIn]),
                       .systemDefault)
    }

    func testChosenDeviceIsHonoured() {
        XCTAssertEqual(
            AudioInputSelection.resolve(preferredUID: airpods.uid, available: [builtIn, airpods]),
            .device(airpods))
    }

    /// Falling back is right — you can still dictate. Falling back SILENTLY
    /// would not be: the symptom is a transcript that is quietly poor for no
    /// visible reason, so the caller is handed the missing uid to say so.
    func testUnpluggedDeviceFallsBackAndSaysWhichOneIsMissing() {
        let resolution = AudioInputSelection.resolve(preferredUID: airpods.uid,
                                                     available: [builtIn])
        XCTAssertEqual(resolution, .unavailable(uid: airpods.uid))
        XCTAssertNil(resolution.device, "must not route to a device that is not here")
    }

    /// Nothing at all plugged in is still not a crash.
    func testEmptyDeviceListIsHandled() {
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "", available: []), .systemDefault)
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: "gone", available: []),
                       .unavailable(uid: "gone"))
    }

    /// `.systemDefault` and `.unavailable` both mean "leave the engine alone",
    /// and the capture path distinguishes them by this being nil.
    func testOnlyAnHonouredPreferenceRoutes() {
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "", available: [builtIn]).device)
        XCTAssertNil(AudioInputSelection.resolve(preferredUID: "gone", available: [builtIn]).device)
        XCTAssertNotNil(AudioInputSelection.resolve(preferredUID: builtIn.uid,
                                                    available: [builtIn]).device)
    }

    /// UIDs are matched exactly — a device whose NAME matches is not the device.
    func testMatchingIsByStableIdentifierNotName() {
        let renamed = AudioInputDevice(uid: "other-uid", name: airpods.name, channels: 1)
        XCTAssertEqual(AudioInputSelection.resolve(preferredUID: airpods.uid, available: [renamed]),
                       .unavailable(uid: airpods.uid))
    }
}
