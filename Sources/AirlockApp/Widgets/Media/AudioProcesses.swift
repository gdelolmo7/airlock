import AirlockCore
import AppKit
import CoreAudio

/// CoreAudio's list of processes making or taking sound, and which app each
/// belongs to. Shared by per-app volume (who is playing) and the call pill
/// (who is on the microphone). Reading it needs no permission: it is a
/// property read, not a tap.
enum AudioProcesses {
    /// Every process CoreAudio knows about right now.
    static func objects() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &objects) == noErr else { return [] }
        return objects
    }

    /// The pid's parent, for walking a helper back to the app that spawned it.
    static func parentPID(_ pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }

    /// Which app a sound-making process belongs to.
    ///
    /// Three attempts, cheapest and most certain first. The middle one is what
    /// makes browsers work: a Chrome tab's audio comes from a helper whose pid
    /// is not an application at all, but whose parent is Chrome. Verified — every
    /// `Google Chrome Helper` on this machine has the main Chrome process as its
    /// direct parent.
    ///
    /// **Known gap:** Safari renders media in WebKit XPC services that are
    /// children of `launchd`, not of Safari, and whose bundle ID
    /// (`com.apple.WebKit.WebContent`) shares no prefix with `com.apple.Safari`.
    /// None of the three finds it. Doing so needs the responsible-process API,
    /// which is not public; until then Safari audio simply gets no row, which is
    /// the right failure — no row beats somebody else's row.
    static func owner(of pid: pid_t,
                              bundleID: String?,
                              running: [NSRunningApplication],
                              bundleIDs: [String]) -> NSRunningApplication? {
        if let direct = running.first(where: { $0.processIdentifier == pid }) { return direct }

        var walker = pid
        // Bounded: a cycle here would hang the enumeration on the main actor,
        // and no real process tree needs more than a couple of hops.
        for _ in 0..<6 {
            guard let parent = parentPID(walker), parent > 1 else { break }
            if let app = running.first(where: { $0.processIdentifier == parent }) { return app }
            walker = parent
        }

        guard let bundleID,
              let owner = AppMix.owningBundleID(forHelper: bundleID, among: bundleIDs)
        else { return nil }
        return running.first { $0.bundleIdentifier == owner }
    }

    static func string(_ object: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value as String?
    }

    static func bool(_ object: AudioObjectID,
                     _ selector: AudioObjectPropertySelector) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    static func pid(_ object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyPID,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr,
              value > 0 else { return nil }
        return value
    }
}
