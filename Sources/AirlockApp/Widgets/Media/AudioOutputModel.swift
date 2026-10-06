import AirlockCore
import CoreAudio
import Observation

/// Which output device sound is going to, and how loud.
///
/// macOS puts this behind an Option-click on the menu bar's sound icon, which
/// almost nobody knows about — so switching between AirPods, speakers and a
/// display is a genuinely awkward thing on an otherwise polished system. It sits
/// under the media card because that is where you already are when you want it.
///
/// Entirely push-driven. CoreAudio notifies when devices appear, disappear or
/// the default changes, and — on the device itself — when volume or mute moves.
///
/// Volume very nearly shipped unwatched, on the reasoning that its properties
/// live on the device rather than the system object, so the listener has to be
/// torn down and rebuilt on every output switch. That is true, and it is about
/// fifteen lines; the symptom of skipping it was a slider that sat still while
/// the hardware keys changed the volume underneath it. `rebindVolumeListeners`
/// is that bookkeeping.
@MainActor
@Observable
final class AudioOutputModel {
    private(set) var devices: [AudioOutputDevice] = []
    private(set) var currentUID: String?
    /// When the default output last MOVED. nil until it does.
    ///
    /// **Only a real move counts.** `refresh()` runs on every CoreAudio
    /// notification — a device appearing, a device going away, listeners
    /// rebinding — and once from `start()`. Stamping on anything other than
    /// `currentUID` changing away from a previous NON-NIL value gives an island
    /// that blinks at every launch and every time a USB device is plugged in,
    /// announcing a route change that never happened. `adoptCurrent` is the one
    /// place both facts are set, so they cannot come apart.
    private(set) var routeChangedAt: Date?
    /// nil when the current device has no software volume — HDMI and many
    /// external DACs do not. A slider that moves nothing is worse than none.
    private(set) var volume: Float?
    private(set) var isMuted = false
    /// Whether the mute glyph is a button or just a readout. Not every device
    /// has a settable mute — see `AudioDevices.canMuteOutput`.
    private(set) var canMute = false

    /// How many chips the media card has room for. Overflow is counted, never
    /// silently dropped — see `AudioOutputMenu`.
    static let visibleLimit = 3

    @ObservationIgnored private var listeners: [AudioObjectPropertyListenerBlock] = []
    /// The device we are currently watching, and the blocks watching it. Held
    /// together because removing a listener needs the same device id it was
    /// added to — keeping only the blocks would leak them onto whichever device
    /// happened to be current at teardown.
    @ObservationIgnored private var volumeWatch: (id: AudioDeviceID,
        listeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)])?
    /// The level captured on the way into a mute WE performed, for the devices
    /// that zero their volume while muted. See `OutputMute.levelToRestore`.
    @ObservationIgnored private var levelBeforeMute: Float?

    /// The default output moved. Fires only on a real move — see
    /// `routeChangedAt` — and exists because this model had no change callback
    /// at all: without it a route change would update nothing on the island
    /// until something unrelated happened to redraw it.
    @ObservationIgnored var onRouteChange: (() -> Void)?

    var layout: AudioOutputMenu.Layout {
        AudioOutputMenu.layout(devices: devices, currentUID: currentUID, limit: Self.visibleLimit)
    }

    /// Where sound is going, by name, for anything that has to SAY it.
    ///
    /// Optional rather than defaulted because CoreAudio's current-device UID can
    /// legitimately name a device that is not in the enumerated list for a beat
    /// — see `AudioOutputMenu.layout`. Better to say nothing than to invent a
    /// chip.
    var currentDeviceName: String? {
        guard let currentUID else { return nil }
        return devices.first { $0.uid == currentUID }?.name
    }

    /// Where sound is going, by KIND, for anything that has to draw it.
    ///
    /// `.unknown` in exactly the beat that leaves `currentDeviceName` nil, and
    /// that is the point of it being an enum with a neutral member rather than
    /// an optional: the glyph has to draw something, and the honest something is
    /// the plain speaker. See `AudioOutputDevice.Transport`.
    var currentTransport: AudioOutputDevice.Transport {
        guard let currentUID else { return .unknown }
        return devices.first { $0.uid == currentUID }?.transport ?? .unknown
    }

    /// Whether the output row draws anything. One switchable device and no
    /// software volume is a row with nothing in it.
    ///
    /// Public because the card above it needs the same answer to know which of
    /// its sections is FIRST, and therefore which one must not draw a divider
    /// above itself. Recomputing that rule in the view would be two copies of a
    /// condition that has to agree.
    var hasRow: Bool { layout.shown.count > 1 || volume != nil }

    func start() {
        refresh()
        listeners = AudioDevices.observeChanges { [weak self] in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    func refresh() {
        devices = AudioDevices.outputs()
        adoptCurrent(AudioDevices.currentOutputUID())
        // A capability of the device, so it belongs with the device change and
        // not with the level — no amount of pressing the mute key makes a
        // device grow a mute property.
        canMute = AudioDevices.canMuteOutput()
        readLevel()
        rebindVolumeListeners()
    }

    /// Take the new current device, and stamp the move if it IS one.
    ///
    /// The one place `currentUID` is written from a fresh read, so the stamp
    /// cannot drift from the thing it describes. A first read (`previous == nil`,
    /// at launch) is not a move; neither is the same UID arriving again because
    /// some other device came or went.
    ///
    /// A click announces only once the switch has gone through (`select`), so
    /// a refused one is never logged as a move.
    private func adoptCurrent(_ uid: String?, announces: Bool = true) {
        let previous = currentUID
        currentUID = uid
        guard let uid, let previous, previous != uid else { return }
        routeChangedAt = Date()
        if announces { Moments.shared.announce(.outputSwitched) }
        onRouteChange?()
    }

    /// Just the level, for the listener — re-enumerating every device on each
    /// press of the volume key would be absurd.
    private func readLevel() {
        volume = AudioDevices.outputVolume()
        isMuted = AudioDevices.isOutputMuted()
        // Audible again means there is nothing left to come back to. This also
        // catches an unmute we did not perform — the hardware key, System
        // Settings — after which a level stashed by an older mute is stale, and
        // writing a stale one over whatever the user has set since is worse
        // than not restoring at all.
        if !isMuted { levelBeforeMute = nil }
    }

    /// Move the volume/mute listeners onto whichever device is now the output.
    /// A no-op when it has not changed, so this is safe to call from `refresh`.
    private func rebindVolumeListeners() {
        let id = AudioDevices.currentOutputID()
        guard volumeWatch?.id != id else { return }

        if let watch = volumeWatch {
            AudioDevices.removeVolumeListeners(watch.listeners, from: watch.id)
            volumeWatch = nil
        }
        guard let id else { return }
        let listeners = AudioDevices.addVolumeListeners(to: id) { [weak self] in
            Task { @MainActor [weak self] in self?.readLevel() }
        }
        if !listeners.isEmpty { volumeWatch = (id, listeners) }
    }

    func select(_ device: AudioOutputDevice) {
        guard device.uid != currentUID else { return }
        // Optimistic, then confirmed. CoreAudio's default-device change lands a
        // beat later, and a chip that stays unselected for that beat reads as a
        // click that did nothing.
        let previous = currentUID
        let previousStamp = routeChangedAt
        // Stamped here too, and not only in `refresh()`, so the acknowledgement
        // is on screen from the click rather than from CoreAudio's beat later.
        adoptCurrent(device.uid, announces: false)
        guard AudioDevices.setDefaultOutput(uid: device.uid) else {
            currentUID = previous
            // Unwound WITH `currentUID`. An acknowledgement left standing for a
            // move that did not happen is the island reporting a failed click as
            // if it had worked — the one thing worse than saying nothing.
            routeChangedAt = previousStamp
            onRouteChange?()
            return
        }
        Moments.shared.announce(.outputSwitched, "picked")
        refresh()
    }

    func setVolume(_ value: Float) {
        volume = value
        // A level set by hand replaces the one stashed on the way into the
        // mute. The slider is deliberately left live while muted so it can BE
        // the level you come back to; restoring the older one over it would
        // throw away the choice the person just made — mute at 50, drag to 0,
        // unmute, and the volume jumped back to 50.
        levelBeforeMute = nil
        AudioDevices.setOutputVolume(value)
    }

    /// Muting is the most common thing anyone does to volume, and the glyph
    /// beside the slider only ever reported it.
    ///
    /// The mute property is toggled on its own, exactly like the key on the
    /// keyboard: the level is left where it is, so the slider stays meaningful
    /// while muted and unmuting comes back to where you were. `levelBeforeMute`
    /// is the fallback for devices that zero their volume instead.
    func toggleMute() {
        guard canMute else { return }
        let muting = !isMuted
        // The level we are SHOWING, not a fresh read, and kept only once the
        // write lands: on a device that zeroes its volume the property has
        // already gone to 0 by the time `setOutputMuted` returns, and a mute
        // the device refused should leave nothing stashed behind it.
        let showing = volume
        guard AudioDevices.setOutputMuted(muting) else { return }
        if muting {
            levelBeforeMute = showing
        } else if let level = OutputMute.levelToRestore(
            reported: AudioDevices.outputVolume(), remembered: levelBeforeMute) {
            AudioDevices.setOutputVolume(level)
        }
        // The property listener will say the same thing a beat later; reading
        // now is what keeps the glyph from lagging its own click.
        readLevel()
    }
}
