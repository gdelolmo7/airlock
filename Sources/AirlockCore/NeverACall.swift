import Foundation

/// Apps that hold the microphone and play sound without anybody on the other
/// end: they must never show the call pill, and call notes must never be
/// offered for them.
///
/// **The call test cannot tell these apart on its own.** A call is an app on
/// the microphone that is also playing (see `MicUser.playing`), and most
/// things that listen do play something: a voice-mode assistant speaks back,
/// GarageBand plays the backing track you are recording over, a dictation app
/// chimes when it starts, a screen recorder monitors what it records. Each of
/// those looked like a call and offered to take notes on nobody. The system
/// speech daemon (corespeechd, "Hey Siri") is the best-known false alarm of
/// this kind, so it and Siri's other speech and dictation daemons are here
/// too, beside Airlock's own dictation.
///
/// **Matched on bundle ID**, because that is what Core Audio's process list
/// gives without a permission, and on the PROCESS as well as the app it
/// resolves to: a daemon is skipped before anything tries to find its owner.
/// An entry covers its exact ID and anything under it after a dot, so an
/// app's helpers go with it (`com.superduper.superwhisper.helper`) while an
/// app whose name merely starts the same way (`com.airlocksoftware`) does not.
/// Case is ignored: macOS treats bundle IDs that way, and the process list has
/// spelt the same daemon both ways (see `CallDetector.callApp(forDaemon:)`).
///
/// **Wrong in the other direction is worse.** A listed calling app is a call
/// that is never noticed, with nothing on screen to say so, where a missing
/// entry costs a pill that can be ignored. So nothing that places calls is
/// here: no browser, no Zoom, Teams, Slack, Discord, WhatsApp, Webex,
/// FaceTime, and none of FaceTime's call daemons, which `callApp(forDaemon:)`
/// counts as FaceTime. `NeverACallTests` holds that line.
///
/// It overlaps `AppMix.isSystemProcess` on purpose and does not replace it:
/// that list keeps daemons out of the volume mixer and is only ever asked
/// about an owning app; this one is about calls, and is asked first.
public enum NeverACall {
    public static func matches(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        return lowercased.contains { id == $0 || id.hasPrefix($0 + ".") }
    }

    /// Whole vendors where every app is an audio, recording or capture tool,
    /// and single apps elsewhere. Exact IDs, not guesses at a pattern: an
    /// entry that names nothing installed costs nothing, and one that names
    /// a calling app costs a call.
    static let listed: [String] = [
        // Airlock itself, its preview copies and its pre-rename identity.
        // Already left out by process ID; listed so a tap described by bundle
        // ID can never name it either.
        "com.airlock",
        IdentityMigration.Legacy.bundleIdentifier,

        // The system's speech, dictation and Siri.
        "com.apple.corespeechd",
        "com.apple.CoreSpeech",
        "com.apple.assistantd",
        "com.apple.Siri",
        "com.apple.SpeechRecognitionCore",
        "com.apple.speech",

        // Dictation and voice control.
        "com.superduper.superwhisper",
        "com.goodsnooze.MacWhisper",
        "com.electron.wispr-flow",
        "com.prakashjoshipax.VoiceInk",
        "com.talonvoice.Talon",

        // AI assistants with a voice mode.
        "com.openai.chat",
        "com.anthropic.claudefordesktop",
        "ai.perplexity.mac",

        // Screen recorders.
        "com.apple.QuickTimePlayerX",
        "com.apple.screencaptureui",
        "pl.maketheweb.cleanshotx",
        "com.loom.desktop",
        "com.obsproject.obs-studio",
        "com.timpler.screenstudio",
        "com.wulkano.kap",
        "net.telestream.screenflow10",
        "com.techsmith",

        // Music and audio production.
        "com.apple.garageband10",
        "com.apple.logic10",
        "com.apple.mainstage3",
        "com.ableton.live",
        "com.cockos.reaper",
        "org.audacityteam.audacity",
        "com.image-line.flstudio",
        "com.avid.ProTools",
        "com.bitwig.BitwigStudio",
        "com.steinberg",
        "com.rogueamoeba",

        // Voice memos and recorders.
        "com.apple.VoiceMemos",
    ]

    private static let lowercased = listed.map { $0.lowercased() }
}
