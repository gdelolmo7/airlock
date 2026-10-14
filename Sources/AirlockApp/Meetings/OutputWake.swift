import AirlockCore
import CoreAudio
import Foundation

/// A moment of silence sent to Bluetooth headphones just before the call's
/// sound is tapped, so a headset that has let its link doze is awake by the
/// time the other side's first words arrive.
///
/// A Bluetooth headset that has played nothing for a while puts its audio
/// link to sleep, and the first sound sent to it is spent waking it up. The
/// call tap listens through a private device clocked by the output (see
/// `CallAudioTap`), so whatever plays while the headset is still waking is
/// lost to the notes.
///
/// **Silence, and only to Bluetooth.** Zeros are mixed into whatever else is
/// playing, so the call and every other app sound exactly as before; nothing
/// changes device, volume or route. Built-in, wired and AirPlay outputs have
/// no link to wake and are left alone.
enum OutputWake {
    static let length: Duration = .milliseconds(300)

    /// Plays `length` of silence to the current output when it is Bluetooth,
    /// and returns once it has. Never on the main actor: it waits out the
    /// silence. Returns a line for the log.
    nonisolated static func wakeIfBluetooth() async -> String {
        guard let device = AudioDevices.currentOutputID() else { return "wake: no output device" }
        let transport = transport(of: device)
        guard transport == .bluetooth || transport == .bluetoothLE else {
            return "wake: not needed (\(transport))"
        }
        var proc: AudioDeviceIOProcID?
        // `@Sendable` is load-bearing, as in `CallAudioTap.startIO`: without
        // it the block could inherit a caller's main-actor isolation and trap
        // on Core Audio's realtime thread. It only writes zeros into the
        // buffers it is handed: no allocation, no lock.
        let status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) {
            @Sendable _, _, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
        }
        guard status == noErr, let proc else { return "wake: FAILED to make the player (\(status))" }
        defer { AudioDeviceDestroyIOProcID(device, proc) }
        let started = AudioDeviceStart(device, proc)
        guard started == noErr else { return "wake: FAILED to play (\(started))" }
        try? await Task.sleep(for: length)
        AudioDeviceStop(device, proc)
        return "wake: Bluetooth output woken"
    }

    /// How the device is attached; `.unknown` when it does not say.
    private nonisolated static func transport(of id: AudioDeviceID) -> AudioOutputDevice.Transport {
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
}
