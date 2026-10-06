import Foundation

/// Somewhere sound can come out of.
public struct AudioOutputDevice: Equatable, Sendable, Identifiable {
    /// Stable across reboots and reconnects, unlike the numeric `AudioDeviceID`
    /// CoreAudio hands out — the same reasoning as `AudioInputDevice.uid`.
    public let uid: String
    public let name: String
    /// How the device is ATTACHED, which is the only thing about it macOS can
    /// actually prove. See `Transport`.
    ///
    /// Defaulted so a caller that only has a name — the assistant's sample
    /// catalogue, a snapshot fixture — still compiles, and lands on the neutral
    /// glyph rather than a confident wrong one.
    public let transport: Transport

    public var id: String { uid }

    public init(uid: String, name: String, transport: Transport = .unknown) {
        self.uid = uid
        self.name = name
        self.transport = transport
    }

    /// What to draw for this device.
    public var symbol: String { transport.symbol }

    /// Devices that exist in CoreAudio but are not somewhere a person listens.
    ///
    /// macOS builds private aggregates for its own routing and leaves them in
    /// the device list — `CADefaultDeviceAggregate-…` is the one that surfaced
    /// here, offered beside "MacBook Pro Speakers" on a laptop connected to
    /// nothing, under a name no user could interpret. It also made a single-
    /// output Mac look like it had a choice, since the row only appears when
    /// there is more than one device.
    ///
    /// A UID prefix test is a heuristic and is the SECOND line of defence — the
    /// device's own hidden and private-aggregate flags are checked first. It is
    /// here because those flags have to be read per property, per device, and
    /// one that reports neither would otherwise reach the panel. A wrong name in
    /// a list of two is very visible; a missing exotic aggregate is not.
    public static func isInternalUID(_ uid: String) -> Bool {
        internalUIDPrefixes.contains { uid.hasPrefix($0) }
    }

    /// Ours is in the list too: the reactive wave builds a private aggregate
    /// around its process tap for as long as music plays.
    private static let internalUIDPrefixes = [
        "CADefaultDeviceAggregate",
        "com.airlock.",
        "com.agenticnotch.",  // pre-rename builds may still have one registered
    ]
}

public extension AudioOutputDevice {
    /// How a device is attached, straight from `kAudioDevicePropertyTransportType`.
    ///
    /// **This exists so nothing has to guess a device's kind from its NAME.** A
    /// name is a string the owner can set to anything: rename AirPods to "Desk"
    /// and a substring test calls them speakers, while a monitor called "AirPods
    /// Pro Monitor" becomes headphones. The transport is reported by the driver
    /// and survives every rename, so it is the only answer that is about the
    /// device rather than about its label.
    ///
    /// Raw values are CoreAudio's own four-character codes, verbatim from
    /// `AudioHardwareBase.h`. They are spelled out here rather than imported so
    /// the mapping stays pure Core with no framework behind it;
    /// `AudioTransportConstantsTests` (app target, where CoreAudio *is*
    /// available) pins each one to Apple's constant so a typo cannot survive a
    /// build. An unrecognised code is `.unknown`, never a guess.
    enum Transport: String, Sendable, Equatable, CaseIterable {
        case builtIn = "bltn"
        case aggregate = "grup"
        case virtual = "virt"
        case pci = "pci "
        case usb = "usb "
        case fireWire = "1394"
        case bluetooth = "blue"
        case bluetoothLE = "blea"
        case hdmi = "hdmi"
        case displayPort = "dprt"
        case airPlay = "airp"
        case avb = "eavb"
        case thunderbolt = "thun"
        case continuityWired = "ccwd"
        case continuityWireless = "ccwl"
        /// Deprecated by Apple in favour of the two above, still reported by
        /// devices attached to an older driver.
        case continuity = "ccap"
        /// Includes CoreAudio's literal `kAudioDeviceTransportTypeUnknown` (0),
        /// anything Apple adds after this was written, and any code that is not
        /// four printable characters.
        case unknown = ""

        /// Decode CoreAudio's `UInt32` four-character code.
        ///
        /// Big-endian by definition — `'usb '` is `0x75736220` — and the
        /// trailing space in `"pci "` and `"usb "` is part of the code, not
        /// padding to trim.
        public init(fourCharCode code: UInt32) {
            self = Transport(rawValue: Transport.text(of: code)) ?? .unknown
        }

        static func text(of code: UInt32) -> String {
            let bytes = [UInt8(truncatingIfNeeded: code >> 24),
                         UInt8(truncatingIfNeeded: code >> 16),
                         UInt8(truncatingIfNeeded: code >> 8),
                         UInt8(truncatingIfNeeded: code)]
            // Zero — CoreAudio's "unknown" — and anything non-textual fall out
            // here rather than becoming a string of control characters that
            // matches no case anyway.
            guard bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return "" }
            return String(decoding: bytes, as: UTF8.self)
        }

        /// The SF Symbol for a device on this transport.
        ///
        /// The rule throughout is **say only what the transport proves.** A
        /// transport is a wire, not a product: it can tell a monitor from a
        /// laptop, and it cannot tell a Bluetooth speaker from Bluetooth
        /// headphones. Where it cannot tell, the glyph says how the thing is
        /// attached and stops there — a confidently wrong headphone icon is
        /// worse than an honest neutral one, because only the wrong one gets
        /// believed.
        ///
        /// - `builtIn` is `laptopcomputer` and not a speaker: it is *this Mac*.
        ///   The product requires a physical notch (see `Package.swift`), so the
        ///   Mac in question is always a laptop. Note that the built-in speakers
        ///   and the built-in microphone share this transport and nothing else
        ///   separates them — but direction already has: an `AudioOutputDevice`
        ///   is only ever built from a device with output channels
        ///   (`AudioDevices.outputs()`), so the microphone never reaches here
        ///   and no name test is needed to keep it out.
        /// - Bluetooth is `wave.3.right`, deliberately NOT `headphones`. A
        ///   Bluetooth speaker is every bit as common as Bluetooth earbuds and
        ///   the transport cannot distinguish them; "wireless" is the part that
        ///   is true of both. Working out that it is specifically AirPods needs
        ///   the Bluetooth product ID, which is a different framework and a
        ///   different feature.
        /// - HDMI is a television or a receiver; DisplayPort is a monitor. That
        ///   is what each cable is for, and it is the one place the transport
        ///   genuinely names the product.
        /// - The wired-peripheral transports (USB, Thunderbolt, FireWire, PCI,
        ///   AVB) collapse to one connector glyph. Any of them could be an
        ///   interface, a DAC, a headset or desk speakers.
        /// - `unknown` gets the plain speaker: the neutral glyph the whole card
        ///   already speaks in, which claims nothing.
        public var symbol: String {
            switch self {
            case .builtIn: return "laptopcomputer"
            case .bluetooth, .bluetoothLE: return "wave.3.right"
            case .airPlay: return "airplayaudio"
            case .hdmi: return "tv"
            case .displayPort: return "display"
            case .usb, .thunderbolt, .fireWire, .pci, .avb: return "cable.connector"
            // A device made of devices — a Multi-Output Device is the one people
            // actually build, and it is literally more than one speaker.
            case .aggregate: return "hifispeaker.2.fill"
            // Loopback, BlackHole, a conferencing app's driver: no hardware at
            // the end of it, so nothing physical to draw.
            case .virtual: return "waveform"
            case .continuityWired, .continuityWireless, .continuity: return "iphone"
            case .unknown: return "speaker.wave.2.fill"
            }
        }
    }
}

/// Which output devices to offer, in what order, when the row is only so wide.
///
/// macOS buries output switching behind an Option-click on the menu bar's sound
/// icon, which is the gap this fills — but a notch panel has room for three
/// chips, not eleven. Everything here is about what to do when there are more
/// devices than space.
///
/// Pure, because the rule that matters is easy to get wrong and invisible when
/// you do: the device you are LISTENING ON must never be the one the cap hides.
/// A row that silently omits the current output reads as "switched to nothing".
public enum AudioOutputMenu {
    public struct Layout: Equatable, Sendable {
        /// In display order, current first.
        public var shown: [AudioOutputDevice]
        /// The ones that did not fit, in the same order — what the overflow
        /// control offers. Carried rather than counted, because a count is the
        /// only thing a row can draw from a number, and a drawn count is a
        /// device you cannot switch to: the fourth output was visible in the
        /// panel and reachable only from System Settings, which is the trip
        /// this row exists to save.
        public var overflow: [AudioOutputDevice]

        /// How many did not fit. Zero when everything is visible.
        public var hidden: Int { overflow.count }

        public init(shown: [AudioOutputDevice], overflow: [AudioOutputDevice]) {
            self.shown = shown
            self.overflow = overflow
        }
    }

    /// `currentUID` may name a device that is not in `devices` — unplug an
    /// interface and CoreAudio can report the old default for a beat. That is
    /// not an error and must not produce a phantom chip; the row just shows
    /// nothing as selected until the system settles.
    public static func layout(devices: [AudioOutputDevice],
                              currentUID: String?,
                              limit: Int) -> Layout {
        guard limit > 0 else { return Layout(shown: [], overflow: devices) }

        var ordered = devices
        // Current first, so the thing you are hearing is the thing you read
        // first — and so the cap below can never drop it.
        if let currentUID, let index = ordered.firstIndex(where: { $0.uid == currentUID }) {
            ordered.insert(ordered.remove(at: index), at: 0)
        }

        let shown = Array(ordered.prefix(limit))
        return Layout(shown: shown, overflow: Array(ordered.dropFirst(shown.count)))
    }
}

/// What muting the system output takes beyond flipping the mute property.
///
/// Pure, because the case that matters is invisible in normal use: most devices
/// leave the level alone across a mute, so unmuting restores it and there is
/// nothing to do here at all. The ones that report zero while muted would
/// otherwise come back into silence — a button that visibly did nothing.
public enum OutputMute {
    /// Below this there is no sound, whatever the mute property says. The glyph
    /// beside the slider reports either kind of silence, so both ends of this
    /// have to agree on where silence starts.
    public static let silenceThreshold: Float = 0.01

    /// Silent by either route: the mute property, or a level below anything
    /// audible. The things that report silence WITHOUT naming its cause — the
    /// glyph, the tint — have to agree on where it starts, so neither compares
    /// against a number of its own.
    ///
    /// This is not the test for the WORD "muted"; see `spokenLevel`. A crossed-
    /// out speaker is true of both kinds of silence, and a device sitting at
    /// zero with its mute property off is not muted.
    ///
    /// A device with no software volume at all (HDMI, many a DAC) has only the
    /// mute property to go on, which is why this takes an optional.
    public static func isSilent(volume: Float?, isMuted: Bool) -> Bool {
        guard let volume else { return isMuted }
        return isMuted || volume < silenceThreshold
    }

    /// What the level READS as, with any mute first.
    ///
    /// VoiceOver is handed the value and nothing else — none of the grey tint
    /// or the crossed-out speaker that say it on screen — so "62 percent" on a
    /// muted Mac is not a summary, it is a wrong answer to the only question
    /// being asked. The level follows rather than disappearing, because muted
    /// is exactly where you set the one you want to come back to.
    ///
    /// Two things this deliberately does NOT do, both of them mistakes it made:
    ///
    /// - It does not say "was". The slider is live while muted — it is pointedly
    ///   not disabled, precisely so the return level can be set — so somebody
    ///   dragging a muted output hears the number they are moving right now.
    ///   "was 70 percent" describes a past that is not past.
    /// - It does not call a level of zero "muted". The word names the mute
    ///   property, and while that property is off the button one control away
    ///   offers "Mute Output"; two adjacent elements must not disagree about
    ///   whether this device is muted. Zero percent already says there is no
    ///   sound, which is why it needs no extra word — silence and mutedness are
    ///   different claims and only one of them is being made.
    public static func spokenLevel(volume: Float, isMuted: Bool) -> String {
        let percent = Int((volume * 100).rounded())
        guard isMuted else { return "\(percent) percent" }
        // Nothing behind the mute: "muted, 0 percent" says the same thing twice,
        // and zero is not a level anybody is coming back to.
        return percent > 0 ? "muted, \(percent) percent" : "muted"
    }

    /// The level to write on the way OUT of mute, or nil when the device came
    /// back somewhere audible by itself and must not be overwritten.
    ///
    /// `remembered` is the level captured on the way in. A remembered silence
    /// buys nothing, so it is not restored: a slider dragged to the bottom
    /// before muting is silence somebody chose, and unmuting into a level
    /// nobody asked for would be worse than leaving it there — which is also
    /// what the key on the keyboard does.
    public static func levelToRestore(reported: Float?, remembered: Float?) -> Float? {
        guard let reported, reported < silenceThreshold else { return nil }
        guard let remembered, remembered >= silenceThreshold else { return nil }
        return remembered
    }
}
