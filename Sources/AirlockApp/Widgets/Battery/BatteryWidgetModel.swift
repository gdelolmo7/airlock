import AirlockCore
import Foundation
import IOKit.ps
import Observation

/// Battery state, decoupled from IOKit. `nil` overall means no battery
/// (a desktop Mac) — the widget hides itself entirely.
struct BatteryState: Equatable {
    var percentage: Int
    var isCharging: Bool
    var isCharged: Bool
    var isPluggedIn: Bool
    var minutesRemaining: Int?

    var isLow: Bool { percentage <= 20 && !isPluggedIn }
    var isCritical: Bool { percentage <= 10 && !isPluggedIn }

    /// One sentence, for the tooltip and the screen reader both. The wording is
    /// `BatteryReading`'s (Core, pure, tested) rather than this view layer's, so
    /// that this and the compact island's critical rung describe the same
    /// battery the same way — including when there is no estimate at all.
    var spoken: String {
        BatteryReading.status(percentage: percentage, isCharging: isCharging,
                              isPluggedIn: isPluggedIn, isCharged: isCharged,
                              minutesRemaining: minutesRemaining)
    }
}

/// Reads the battery via IOKit power sources. No TCC, no entitlement, no
/// external process. Gutter-only by design: it never forces the island open, it
/// just sits at the far right of the top bar when you expand.
///
/// **The reading is pushed, not polled.** IOKit publishes power-source changes
/// (`IOPSNotificationCreateRunLoopSource`), so pulling the cable updates the
/// glyph at the instant it happens instead of up to ten seconds later, and a Mac
/// sitting at 100% on mains costs nothing at all. The timer that remains is a
/// five-minute FLOOR, not the mechanism — see `safetyInterval`.
@MainActor
@Observable
final class BatteryWidgetModel {
    private(set) var state: BatteryState?

    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.battery.enabled", defaultValue: true)
    /// Stored, not computed over UserDefaults: `@Observable` cannot track a
    /// computed property reading `@ObservationIgnored` storage, so toggling this
    /// in settings wrote the value without invalidating anything that reads it.
    var isEnabled: Bool = WidgetToggle.stored("widget.battery.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if !isEnabled { state = nil }
            onChange?()
            if isEnabled { refresh() }
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var powerSource: CFRunLoopSource?
    /// The `+1` on `self` that the C callback's context pointer stands for.
    /// Non-nil exactly when `powerSource` is.
    @ObservationIgnored private var callbackContext: UnsafeMutableRawPointer?

    /// Five minutes. The notification is the mechanism; this is the guarantee.
    ///
    /// `IOPSNotificationCreateRunLoopSource` fires on the time-remaining
    /// notification, which covers attach, detach and estimate changes — but the
    /// gutter draws a *percentage*, and a percentage can drift a point without
    /// the estimate moving. It is also a run-loop source, so an event that
    /// arrives while the app is suspended is coalesced rather than queued. Five
    /// minutes bounds how stale the drawn number can get in either case, at 1/30
    /// the wakeups of the ten-second poll it replaces — for a figure that changes
    /// by the minute at best, that is still an over-sampling.
    private static let safetyInterval: Duration = .seconds(300)

    func start() {
        observePowerSource()
        refresh()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.safetyInterval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    /// Balances `start()`. Nothing calls it today — the model is owned by the app
    /// delegate for the life of the process — but it is what makes the retained
    /// context pointer below correct rather than merely lucky.
    func stop() {
        pollTask?.cancel()
        pollTask = nil
        if let powerSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes)
            CFRunLoopSourceInvalidate(powerSource)
        }
        powerSource = nil
        // Cleared BEFORE the release, because the release may be the last
        // reference there is: writing a stored property of a freed `self` is the
        // one way this teardown could crash.
        let context = callbackContext
        callbackContext = nil
        if let context { Unmanaged<BatteryWidgetModel>.fromOpaque(context).release() }
    }

    /// Subscribe to power-source changes.
    ///
    /// Two deliberate choices at this OS boundary, both about staying safe under
    /// Swift 6 without an `@unchecked Sendable`:
    ///
    /// - The callback is a C function pointer and therefore captures nothing, so
    ///   `self` travels as a raw context pointer. It is **retained**, and
    ///   released only in `stop()`. An unretained pointer is the usual shape and
    ///   is a use-after-free waiting for the one day this model is released with
    ///   the source still installed; a `+1` makes "installed" and "alive" the
    ///   same condition, and costs one object for the process lifetime.
    /// - The source is scheduled on the MAIN run loop, so the callback runs on
    ///   the main thread — which is precisely what `MainActor.assumeIsolated`
    ///   asserts. Nothing crosses a thread and nothing is smuggled past the
    ///   compiler: the pointer becomes a model again *inside* the isolation it
    ///   never left, so no type here needs to claim a Sendable it does not have.
    ///
    /// `.commonModes` rather than `.defaultMode`: a menu or a drag puts the main
    /// run loop in a tracking mode, and a cable pulled during one still counts.
    private func observePowerSource() {
        guard powerSource == nil else { return }
        let context = Unmanaged.passRetained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ raw in
            guard let raw else { return }
            MainActor.assumeIsolated {
                Unmanaged<BatteryWidgetModel>.fromOpaque(raw).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue() else {
            Unmanaged<BatteryWidgetModel>.fromOpaque(context).release()
            return
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        powerSource = source
        callbackContext = context
    }

    func refresh() {
        guard isEnabled else { return }
        guard
            let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
            let first = sources.first,
            let desc = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any]
        else {
            if state != nil { state = nil; onChange?() } // desktop / no battery
            return
        }

        let current = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maximum = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let percentage = maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : current
        let charging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let pluggedIn = (desc[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
        let charged = desc[kIOPSIsChargedKey] as? Bool ?? false
        let remaining = charging
            ? desc[kIOPSTimeToFullChargeKey] as? Int
            : desc[kIOPSTimeToEmptyKey] as? Int

        let next = BatteryState(
            percentage: percentage,
            isCharging: charging,
            isCharged: charged,
            isPluggedIn: pluggedIn,
            // IOKit reports -1 while still estimating.
            minutesRemaining: (remaining ?? -1) > 0 ? remaining : nil
        )
        if next != state {
            state = next
            onChange?()
        }
    }
}
