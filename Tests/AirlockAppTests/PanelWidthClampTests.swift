import AirlockTestSupport
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The arithmetic of the width ceiling is `PanelWidthLimitTests`' job. This is
/// the half that lives in the model and that the pure tests cannot see: the
/// clamp is applied on READ and the preference is left exactly as the user
/// wrote it, so a width chosen on a wider display comes back when that display
/// does.
@MainActor
final class PanelWidthClampTests: XCTestCase {
    /// Held for the test case's life, so its domain and its file in
    /// ~/Library/Preferences both go with it — see `TestDefaults`.
    private var stores: [TestDefaults] = []

    override func tearDownWithError() throws {
        stores.forEach { $0.remove() }
        stores.removeAll()
    }

    private func suite() -> UserDefaults {
        let store = TestDefaults("com.airlock.test.panelwidth")
        stores.append(store)
        return store.defaults
    }

    /// Whatever screen this runs on, what the panel draws at is inside the
    /// range the slider offers. A value outside it is a slider that cannot
    /// reach its own position.
    func testTheDrawnWidthIsAlwaysInsideTheOfferedRange() {
        let defaults = suite()
        defaults.set(Double(NotchAppearanceModel.requestedWidthRange.upperBound),
                     forKey: "notch.panelWidth")
        let model = NotchAppearanceModel(defaults: defaults)
        XCTAssertTrue(model.widthRange.contains(model.panelWidth),
                      "\(model.panelWidth) is outside \(model.widthRange)")
    }

    /// The rule the doc comment states, and the one nobody could check before:
    /// reading a too-wide preference must not quietly replace it with the
    /// ceiling. Rewriting would turn "temporarily on a small screen" into a
    /// permanent downgrade of a choice the user made.
    func testReadingATooWideWidthDoesNotRewriteThePreference() {
        let defaults = suite()
        let chosen = Double(NotchAppearanceModel.requestedWidthRange.upperBound)
        defaults.set(chosen, forKey: "notch.panelWidth")

        let model = NotchAppearanceModel(defaults: defaults)
        _ = model.panelWidth
        _ = model.budget
        _ = model.widthAdvice(batteryVisible: true, usageVisible: true)

        XCTAssertEqual(defaults.double(forKey: "notch.panelWidth"), chosen)
    }

    /// Everybody starts at the default, so it has to be drawable on the
    /// narrowest Mac the product runs on, a 13" Air at 1470pt. Checked against
    /// the model's own constants: raise the default past that screen's ceiling
    /// and every 13" user starts out clamped.
    func testTheDefaultWidthIsDrawableOnAThirteenInchAir() {
        let air13 = PanelWidthLimit(screenWidth: 1470,
                                    requested: NotchAppearanceModel.requestedWidthRange)
        XCTAssertEqual(air13.clamped(NotchAppearanceModel.defaultPanelWidth),
                       NotchAppearanceModel.defaultPanelWidth)
    }

    /// Setting one, by contrast, is a statement and is persisted verbatim —
    /// through the store the model was handed, not a global one.
    func testSettingAWidthPersistsItRaw() {
        let defaults = suite()
        let model = NotchAppearanceModel(defaults: defaults)
        model.panelWidth = NotchAppearanceModel.requestedWidthRange.lowerBound

        XCTAssertEqual(defaults.double(forKey: "notch.panelWidth"),
                       Double(NotchAppearanceModel.requestedWidthRange.lowerBound))
    }
}
