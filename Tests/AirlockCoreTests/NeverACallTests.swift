import XCTest
@testable import AirlockCore

final class NeverACallTests: XCTestCase {
    func testEachKindOfAppIsListed() {
        let listed = [
            "com.apple.corespeechd",          // the system's speech daemon
            "com.apple.assistantd",           // Siri
            "com.airlock.app",                // Airlock
            "com.airlock.app.preview",        // a preview copy of it
            "com.agenticnotch.app",           // its name before the rename
            "com.superduper.superwhisper",    // dictation
            "com.openai.chat",                // a voice-mode assistant
            "pl.maketheweb.cleanshotx",       // a screen recorder
            "com.apple.garageband10",         // music
            "com.apple.logic10",
            "com.apple.VoiceMemos",           // a recorder
        ]
        for id in listed { XCTAssertTrue(NeverACall.matches(id), id) }
    }

    func testAnAppsHelpersGoWithIt() {
        XCTAssertTrue(NeverACall.matches("com.superduper.superwhisper.helper"))
        XCTAssertTrue(NeverACall.matches("com.openai.chat.Helper.Renderer"))
        XCTAssertTrue(NeverACall.matches("com.apple.corespeechd.xpc"))
    }

    func testOnlyADotStartsAHelper() {
        // An app whose ID merely begins the same way is somebody else's.
        XCTAssertFalse(NeverACall.matches("com.airlocksoftware.mail"))
        XCTAssertFalse(NeverACall.matches("com.openai.chatter"))
        XCTAssertFalse(NeverACall.matches("com.apple.logic100"))
    }

    func testCaseIsIgnored() {
        XCTAssertTrue(NeverACall.matches("COM.APPLE.COREspeechd"))
        XCTAssertTrue(NeverACall.matches("com.apple.voicememos"))
        XCTAssertTrue(NeverACall.matches("Com.SuperDuper.SuperWhisper"))
    }

    func testNoCallingAppIsEverListed() {
        // A listed calling app is a call nobody is told about, so this is the
        // line the list must never cross: the apps, their helpers, the
        // browsers a call runs in, and FaceTime's call daemons.
        let calling = [
            "us.zoom.xos", "us.zoom.CptHost",
            "com.microsoft.teams2", "com.microsoft.teams2.helper",
            "com.tinyspeck.slackmacgap", "com.tinyspeck.slackmacgap.helper",
            "com.hnc.Discord", "com.hnc.Discord.helper",
            "net.whatsapp.WhatsApp", "desktop.WhatsApp",
            "Cisco-Systems.Spark", "com.skype.skype", "com.apple.FaceTime",
            "com.google.Chrome", "com.google.Chrome.helper",
            "com.apple.Safari", "com.apple.WebKit.GPU", "com.apple.WebKit.WebContent",
            "org.mozilla.firefox", "com.microsoft.edgemac", "com.brave.Browser",
            "company.thebrowser.Browser", "com.github.Electron.helper",
            "com.apple.avconferenced",
            "com.apple.TelephonyUtilities.callservicesd",
            "com.apple.telephonyutilities.callservicesd",
            "com.apple.callservicesd",
        ]
        for id in calling { XCTAssertFalse(NeverACall.matches(id), id) }
    }

    func testFaceTimesDaemonsStillCountAsFaceTime() {
        // The two lists must not disagree about the one calling app every Mac has.
        for daemon in ["com.apple.avconferenced", "com.apple.TelephonyUtilities.callservicesd",
                       "com.apple.callservicesd"] {
            XCTAssertEqual(CallDetector.callApp(forDaemon: daemon), CallDetector.faceTime)
            XCTAssertFalse(NeverACall.matches(daemon), daemon)
        }
    }

    func testTheListHasNoBlanksOrRepeats() {
        let lowered = NeverACall.listed.map { $0.lowercased() }
        XCTAssertFalse(lowered.contains(where: \.isEmpty))
        XCTAssertFalse(lowered.contains { $0.hasSuffix(".") || $0.contains(" ") })
        XCTAssertEqual(Set(lowered).count, lowered.count)
    }
}
