import SwiftUI
import AirlockCore

/// Panel appearance the user can change, held observably so the notch redraws
/// the moment a setting moves — these are read during layout, and a plain
/// UserDefaults read would only take effect on the next unrelated redraw.
///
/// Deliberately small. Every value here changes something the app genuinely
/// does; a switch that controls nothing is worse than an absent one.
@MainActor
@Observable
final class NotchAppearanceModel {
    /// Expanded panel width. Adjustable because it is not a free choice — the
    /// gutters have to hold their content, and content that outgrows a gutter
    /// spills under the camera housing. `widthAdvice` says so live rather than
    /// letting you discover it by eye.
    ///
    /// The default moved 580 → 640 when the settings gear joined the trailing
    /// gutter: 580 gives a 197.5pt gutter against ~218pt of demand.
    ///
    /// Clamped on READ to what the screen can draw, and stored raw — see
    /// `widthLimit`. A width chosen on a larger display is not a mistake to be
    /// corrected: writing the ceiling back would replace a stated choice with a
    /// smaller number nobody made, and the original is drawable again the moment
    /// that display is.
    var panelWidth: CGFloat {
        get { widthLimit.clamped(storedPanelWidth) }
        set { storedPanelWidth = newValue }
    }

    private var storedPanelWidth: CGFloat {
        didSet { store(storedPanelWidth, Keys.panelWidth) }
    }

    /// How much NARROWER than the measured cutout to reserve. Above zero is a
    /// gamble: the measured width is the real housing, so anything reclaimed is
    /// space content can be drawn behind.
    var centreTightening: CGFloat {
        didSet { store(centreTightening, Keys.centreTightening) }
    }

    /// Panel text size, 1.0–1.4.
    ///
    /// Apple asks for text to be enlargeable by at least 200 percent and
    /// explicitly allows CUSTOM UI rather than Dynamic Type to do it — which
    /// matters, because Dynamic Type does not reach a custom-drawn panel like
    /// this one. **This does not meet that bar yet**, and the ceiling says so:
    /// see `Theme.maxTextScale`. Shaped exactly like `panelWidth`: a persisted
    /// scalar with a range and a slider.
    ///
    /// The `didSet` is the ONLY writer of `Theme.textScale`. Views cannot
    /// observe a static, so `NotchRootView` re-identifies its content on this
    /// value; see the note on `Theme.textScale` for why that pair matters.
    var textScale: CGFloat {
        didSet {
            store(textScale, Keys.textScale)
            Theme.setTextScale(textScale)
        }
    }

    /// The panel's ground. Black is the default and the identity — the island
    /// reading as one piece with the physical notch. Glass trades that for the
    /// desktop showing through.
    var surface: NotchSurface {
        didSet {
            store(surface.rawValue, Keys.surface)
            // The panel redraws itself from observation, but the kit's own
            // background is not ours to observe — the controller has to be told.
            NotificationCenter.default.post(name: .notchSurfaceDidChange, object: nil)
        }
    }

    var showsUsageInGutter: Bool {
        didSet { store(showsUsageInGutter, Keys.showsUsage) }
    }

    var showsBatteryPercentage: Bool {
        didSet { store(showsBatteryPercentage, Keys.showsBatteryPercentage) }
    }

    private enum Keys {
        static let panelWidth = "notch.panelWidth"
        static let centreTightening = "notch.centreTightening"
        static let surface = "notch.surface"
        static let showsUsage = "notch.showsUsageInGutter"
        static let showsBatteryPercentage = "notch.showsBatteryPercentage"
        static let textScale = "notch.textScale"
    }

    static let defaultPanelWidth: CGFloat = 640
    /// What the product would offer given an unlimited screen. The slider uses
    /// `widthRange`, which is this narrowed to what the host window can draw.
    static let requestedWidthRange: ClosedRange<CGFloat> = 460...760
    /// Derived from `Theme.maxTextScale` so the slider and the clamp cannot
    /// drift apart — see that constant for why it is not Apple's 200%.
    static let textScaleRange: ClosedRange<CGFloat> = 1.0...Theme.maxTextScale

    /// The store the model was constructed against. Held rather than reached
    /// for, because reads and writes have to be the same place: `init` already
    /// took a `defaults` and every setter went to `.standard` regardless, so a
    /// test could seed a value and then never observe what the model did with
    /// it — which is exactly the invariant `panelWidth`'s clamp turns on.
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let stored = defaults.object(forKey: Keys.panelWidth) as? Double
        storedPanelWidth = stored.map { CGFloat($0) } ?? Self.defaultPanelWidth
        centreTightening = CGFloat(defaults.double(forKey: Keys.centreTightening))
        surface = defaults.string(forKey: Keys.surface).flatMap(NotchSurface.init(rawValue:)) ?? .black
        showsUsageInGutter = defaults.object(forKey: Keys.showsUsage) as? Bool ?? true
        showsBatteryPercentage = defaults.object(forKey: Keys.showsBatteryPercentage) as? Bool ?? true
        let scale = defaults.object(forKey: Keys.textScale) as? Double
        textScale = scale.map { CGFloat($0) } ?? 1
        // `didSet` does not fire during init, so the static would stay at 1 for
        // a user who had set a scale — the panel would come up unscaled and only
        // follow the setting after the first nudge of the slider.
        Theme.setTextScale(textScale)
    }

    private func store(_ value: some Any, _ key: String) {
        defaults.set(value, forKey: key)
    }

    // MARK: - Derived

    /// What this screen can actually draw. The kit sizes its window at half the
    /// screen and draws its island 60pt wider than the panel (`IslandChrome`),
    /// so a 14" tops out at 688pt and a 13" Air at 667pt — below the 760 the
    /// slider used to offer. Anything past that is clipped by the window edge
    /// rather than scrolled: the island's corners first, then the trailing
    /// gutter. Pure and tested in Core.
    var widthLimit: PanelWidthLimit {
        PanelWidthLimit(screenWidth: NotchScreen.notched.frame.width,
                        requested: Self.requestedWidthRange)
    }

    /// What the slider may offer here. Not a static, because it depends on the
    /// display the panel is presented on and that changes under the app.
    var widthRange: ClosedRange<CGFloat> { widthLimit.range }

    /// The arithmetic lives in Core, tested — it has misled twice, once by hand
    /// and once in this very advice.
    var budget: GutterBudget {
        GutterBudget(panelWidth: panelWidth,
                     notchWidth: NotchScreen.notched.notchMetrics.notchWidth,
                     tightening: centreTightening)
    }

    var reservedCentreWidth: CGFloat { budget.reservedCentre }

    /// What the LAYOUT lays out against, tightening included.
    var gutterWidth: CGFloat { budget.layoutGutter }

    /// What is actually clear of the camera.
    var clearGutterWidth: CGFloat { budget.clearGutter }

    /// What the trailing gutter needs at the current settings. Measured off the
    /// rendered cluster rather than guessed.
    ///
    /// Both flags are passed in rather than read here, for the same reason: what
    /// actually reaches the gutter is decided by the Widgets toggles, which this
    /// model doesn't own. `showsUsageInGutter` alone is not enough — the usage
    /// figures also disappear with the agent surfaces — and assuming either one
    /// always shows overstated demand and advised widening a panel that fitted.
    func trailingGutterDemand(batteryVisible: Bool, usageVisible: Bool) -> CGFloat {
        var demand: CGFloat = 30 // the settings gear, always present
        if batteryVisible {
            demand += 36
            // Text, so it follows the capped gutter scale. The glyph beside it
            // does not, which is why only this part is multiplied.
            if showsBatteryPercentage { demand += 30 * gutterTextScale }
        }
        if usageVisible { demand += 126 * gutterTextScale }
        return demand
    }

    /// What the gutter's TEXT is actually multiplied by — `Theme.gutter`'s cap,
    /// restated here because these numbers were MEASURED against real rendered
    /// text, not derived from the font size. Multiplying a measurement is an
    /// estimate, so this errs on the side of over-reporting demand: an advice
    /// line that appears slightly early costs a sentence, while one that appears
    /// slightly late means the usage figures are already behind the camera
    /// housing, which is the exact bug the advice exists to prevent.
    private var gutterTextScale: CGFloat { min(textScale, 1.25) }

    /// Non-nil when the trailing gutter can't hold its contents, which is the
    /// failure that puts the usage sparkle behind the camera.
    func widthAdvice(batteryVisible: Bool, usageVisible: Bool) -> String? {
        let demand = trailingGutterDemand(batteryVisible: batteryVisible, usageVisible: usageVisible)
        let budget = budget
        guard !budget.fits(demand) else { return nil }
        let needed = budget.widthNeeded(for: demand)
        let problem = "The status cluster needs about \(Int(demand.rounded()))pt but only "
            + "\(Int(budget.clearGutter.rounded()))pt of gutter is clear of the camera, so it will spill "
            + "behind the housing. "
        // Advising a width the slider does not reach is advice nobody can take,
        // and this screen's ceiling is well under the 760 the range asks for.
        guard needed <= widthRange.upperBound else {
            return problem + "This screen can only draw \(Int(widthRange.upperBound.rounded()))pt, "
                + "so turn something off below."
        }
        return problem + "Widen to \(Int(needed.rounded()))pt, or turn something off below."
    }
}

/// What the expanded panel is drawn on.
///
/// Glass is real material, not a tint — Liquid Glass samples what is behind it.
/// That is precisely why the kit had to be vendored: it painted an opaque black
/// rectangle behind our content, so the glass faithfully blurred solid black and
/// came out a flat grey slab. `DynamicNotch.backgroundStyle` now lets the
/// controller clear that ground while expanded on glass, leaving the desktop
/// genuinely behind us.
enum NotchSurface: String, CaseIterable, Identifiable {
    case black
    case darkGlass
    case lightGlass

    var id: String { rawValue }

    var label: String {
        switch self {
        case .black: return "Black"
        case .darkGlass: return "Dark glass"
        case .lightGlass: return "Light glass"
        }
    }

    /// Flips the whole palette — see `Theme.adaptive`.
    var colorScheme: ColorScheme {
        self == .lightGlass ? .light : .dark
    }

    /// Whether the ground being drawn RIGHT NOW is this surface's glass, which
    /// is not the same question as which surface is set: glass is handed to our
    /// own view only while expanded, and a collapsed island keeps the kit's
    /// black. See `NotchController.applyGround`.
    func isGlassGround(showing: IslandPresentation?) -> Bool {
        showing == .expanded && self != .black
    }

    /// Light-or-dark for that ground — one rule, because two consumers read it
    /// and they used to disagree. `Theme` follows the SwiftUI `colorScheme`
    /// (`NotchRootView`), so the palette always matched this setting; the glass
    /// is AppKit material and follows the WINDOW's appearance, which nothing
    /// pinned and which therefore followed System Settings. Pure and tested,
    /// since a window is a poor place to keep a decision.
    func groundScheme(showing: IslandPresentation?) -> ColorScheme {
        isGlassGround(showing: showing) ? colorScheme : .dark
    }

    /// A square shape because the kit's NotchShape mask already does the
    /// rounding — glass's default `Capsule` would round it a second time,
    /// inside the first. Drawn with generous negative padding by the caller so
    /// it fills that mask entirely.
    @ViewBuilder
    var background: some View {
        switch self {
        case .black:
            Color.black
        case .darkGlass, .lightGlass:
            Color.clear.glassEffect(.regular, in: .rect(cornerRadius: 0))
        }
    }
}
