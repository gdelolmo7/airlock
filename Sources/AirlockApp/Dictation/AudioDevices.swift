import AVFoundation
import CoreAudio
import AirlockCore

/// CoreAudio device enumeration, and translating a saved UID back to the
/// numeric id the audio unit wants.
///
/// `AVCaptureDevice` would give friendlier names with less ceremony, but its
/// identifiers do not translate to `AudioDeviceID` without a second round trip
/// through CoreAudio anyway — so this goes straight to the source and gets both
/// halves from one API.
enum AudioDevices {
    /// Every device with at least one input channel, in system order.
    ///
    /// Output-only devices are filtered by channel count rather than by name:
    /// plenty of interfaces and aggregates are both, and a name test would
    /// mislabel them.
    static func inputs() -> [AudioInputDevice] {
        deviceIDs().compactMap { id in
            let channels = inputChannels(of: id)
            guard channels > 0 else { return nil }
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty else { return nil } // nothing stable to persist
            return AudioInputDevice(uid: uid,
                                    name: string(id, kAudioObjectPropertyName),
                                    channels: channels)
        }
    }

    /// The numeric id for a saved UID, or nil when that device is not present.
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        deviceIDs().first { string($0, kAudioDevicePropertyDeviceUID) == uid }
    }

    // MARK: - Output

    /// Every device with at least one OUTPUT channel, in system order.
    ///
    /// Same channel-count test as `inputs()` and for the same reason: an
    /// interface or an aggregate is usually both, and deciding by name would
    /// mislabel it.
    static func outputs() -> [AudioOutputDevice] {
        deviceIDs().compactMap { id in
            guard channels(of: id, scope: kAudioDevicePropertyScopeOutput) > 0 else { return nil }
            // The device's own flags first — a private aggregate says so, and
            // asking it beats matching its name.
            guard !isHidden(id), !isPrivateAggregate(id) else { return nil }
            let uid = string(id, kAudioDevicePropertyDeviceUID)
            guard !uid.isEmpty, !AudioOutputDevice.isInternalUID(uid) else { return nil }
            return AudioOutputDevice(uid: uid,
                                     name: string(id, kAudioObjectPropertyName),
                                     transport: transport(of: id))
        }
    }

    /// How the device is attached. See `AudioOutputDevice.Transport` for why
    /// this is asked at all rather than read off the device's name.
    ///
    /// A device that does not answer the property reads as `.unknown`, which is
    /// the neutral glyph — the same answer as a transport we have no case for,
    /// and the right one either way.
    private static func transport(of id: AudioDeviceID) -> AudioOutputDevice.Transport {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return .unknown }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return .unknown }
        return AudioOutputDevice.Transport(fourCharCode: value)
    }

    /// CoreAudio's own "do not show this to anyone" flag.
    private static func isHidden(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyIsHidden,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }

    /// An aggregate built for one process rather than for a person.
    ///
    /// Only aggregates answer this property at all, so a plain device falls
    /// straight through — which is why it is safe to ask every device.
    private static func isPrivateAggregate(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioAggregateDevicePropertyComposition,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(id, &address) else { return false }
        var composition: CFDictionary?
        var size = UInt32(MemoryLayout<CFDictionary?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &composition) == noErr,
              let values = composition as? [String: Any] else { return false }
        return (values[kAudioAggregateDeviceIsPrivateKey] as? Bool) == true
            || (values[kAudioAggregateDeviceIsPrivateKey] as? Int) == 1
    }

    static func currentOutputID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &id) == noErr, id != 0
        else { return nil }
        return id
    }

    static func currentOutputUID() -> String? {
        currentOutputID().map { string($0, kAudioDevicePropertyDeviceUID) }
            .flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Make a device the system output. This is the whole feature: macOS only
    /// offers it behind an Option-click on the menu bar's sound icon.
    @discardableResult
    static func setDefaultOutput(uid: String) -> Bool {
        guard var id = deviceID(forUID: uid) else { return false }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                          UInt32(MemoryLayout<AudioDeviceID>.size), &id) == noErr
    }

    // MARK: - Volume

    /// 0…1 for the current output, or nil when the device has no software
    /// volume — an HDMI display or an external DAC often does not, and showing
    /// a slider that moves nothing is worse than showing none.
    static func outputVolume() -> Float? {
        guard let id = currentOutputID() else { return nil }
        var address = volumeAddress
        guard AudioObjectHasProperty(id, &address) else { return nil }
        var value: Float = 0
        var size = UInt32(MemoryLayout<Float>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    @discardableResult
    static func setOutputVolume(_ value: Float) -> Bool {
        guard let id = currentOutputID() else { return false }
        var address = volumeAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr,
              settable.boolValue else { return false }
        var clamped = min(max(value, 0), 1)
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<Float>.size), &clamped) == noErr
    }

    static func isOutputMuted() -> Bool {
        guard let id = currentOutputID() else { return false }
        var address = muteAddress
        guard AudioObjectHasProperty(id, &address) else { return false }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    /// Whether the current output has a mute we are allowed to write.
    ///
    /// Asked separately from setting it so the button can be hidden rather than
    /// merely inert: plenty of aggregates and USB interfaces answer the volume
    /// property but not this one, and a mute button that silently does nothing
    /// is the same mistake as a slider that moves nothing.
    static func canMuteOutput() -> Bool {
        guard let id = currentOutputID() else { return false }
        var address = muteAddress
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(id, &address),
              AudioObjectIsPropertySettable(id, &address, &settable) == noErr else { return false }
        return settable.boolValue
    }

    @discardableResult
    static func setOutputMuted(_ muted: Bool) -> Bool {
        guard let id = currentOutputID(), canMuteOutput() else { return false }
        var address = muteAddress
        var value: UInt32 = muted ? 1 : 0
        return AudioObjectSetPropertyData(id, &address, 0, nil,
                                          UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// Watch volume and mute on ONE device, so the slider follows the hardware
    /// keys instead of only updating when the panel reopens.
    ///
    /// Per device, not global: the properties live on the device object, so the
    /// caller has to unregister and re-register whenever the default output
    /// changes. That is the whole reason this returns its blocks — a listener
    /// left on a device that is no longer the output is both a leak and a source
    /// of updates about something nobody is listening to.
    static func addVolumeListeners(to id: AudioDeviceID,
                                   _ handler: @escaping () -> Void) -> [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] {
        [volumeAddress, muteAddress].compactMap { address in
            var address = address
            guard AudioObjectHasProperty(id, &address) else { return nil }
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            guard AudioObjectAddPropertyListenerBlock(id, &address, .main, block) == noErr
            else { return nil }
            return (address, block)
        }
    }

    static func removeVolumeListeners(_ listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)],
                                      from id: AudioDeviceID) {
        for (address, block) in listeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(id, &address, .main, block)
        }
    }

    /// The main-element scalar, which is the one that follows the hardware keys.
    /// Per-channel volumes exist but drift apart, and a slider bound to only the
    /// left channel is a bug that takes a while to notice.
    private static var volumeAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Notifies whenever devices appear or disappear, or the default changes —
    /// so the row follows an AirPods connection without polling for it.
    static func observeChanges(_ handler: @escaping () -> Void) -> [AudioObjectPropertyListenerBlock] {
        let selectors = [kAudioHardwarePropertyDevices,
                         kAudioHardwarePropertyDefaultOutputDevice]
        return selectors.map { selector in
            var address = AudioObjectPropertyAddress(
                mSelector: selector,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            let block: AudioObjectPropertyListenerBlock = { _, _ in handler() }
            AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &address, .main, block)
            return block
        }
    }

    /// Point an engine's input at a specific device, through its input node's
    /// audio unit.
    ///
    /// MUST happen before the tap format is read. The format follows the
    /// device — measured 24 kHz on the built-in and 48 kHz on another, on the
    /// same machine — so reading it first and switching after yields a
    /// converter configured for a device that is no longer supplying the audio.
    ///
    /// Takes the unit rather than the engine so that every AVFAudio call on the
    /// way here — the input node, its unit — stays in `AudioCapture`, where each
    /// one is guarded against raising. This one is Core Audio: it returns a
    /// status and never raises.
    @discardableResult
    static func route(_ unit: AudioUnit, to deviceID: AudioDeviceID) -> Bool {
        var id = deviceID
        let status = AudioUnitSetProperty(unit,
                                          kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global,
                                          0,
                                          &id,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        return status == noErr
    }

    // MARK: - CoreAudio plumbing

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                             &address, 0, nil, &size) == noErr, size > 0
        else { return [] }

        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &address, 0, nil, &size, &ids) == noErr
        else { return [] }
        return ids
    }

    private static func inputChannels(of id: AudioDeviceID) -> Int {
        channels(of: id, scope: kAudioDevicePropertyScopeInput)
    }

    private static func channels(of id: AudioDeviceID,
                                 scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0
        else { return 0 }

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: 16)
        defer { buffer.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, buffer) == noErr else { return 0 }

        let list = buffer.assumingMemoryBound(to: AudioBufferList.self)
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func string(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr else { return "" }
        return value as String
    }
}
