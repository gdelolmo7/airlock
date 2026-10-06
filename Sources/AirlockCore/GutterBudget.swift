import Foundation
import CoreGraphics

/// Whether the panel's trailing gutter can hold what's in it, or whether the
/// contents will be drawn behind the camera housing.
///
/// Pure and value-typed because this arithmetic has now misled twice. First by
/// hand — a gutter 10pt short put the usage sparkle behind the housing and the
/// only symptom was "the icon looks slightly cut". Then in the settings advice
/// itself, which measured against a gutter inflated by `tightening` and would
/// therefore call a spilling layout fine.
///
/// The distinction that matters: `layoutGutter` is what the layout divides up,
/// `clearGutter` is what the user can actually see. Only the second is a budget.
public struct GutterBudget: Equatable, Sendable {
    public let panelWidth: CGFloat
    /// The measured cutout — what the camera really covers.
    public let notchWidth: CGFloat
    /// How much narrower than the cutout the layout reserves. Every point of
    /// this is gutter the layout believes in and the camera covers.
    public let tightening: CGFloat

    public init(panelWidth: CGFloat, notchWidth: CGFloat, tightening: CGFloat = 0) {
        self.panelWidth = panelWidth
        self.notchWidth = notchWidth
        self.tightening = max(0, tightening)
    }

    public var reservedCentre: CGFloat { max(0, notchWidth - tightening) }

    /// What the layout hands each gutter.
    public var layoutGutter: CGFloat { max(0, (panelWidth - reservedCentre) / 2) }

    /// What is genuinely clear of the housing. Never larger than `layoutGutter`,
    /// and smaller by exactly the tightening.
    public var clearGutter: CGFloat { max(0, (panelWidth - notchWidth) / 2) }

    public func fits(_ demand: CGFloat) -> Bool { demand <= clearGutter }

    /// The narrowest panel that would hold `demand` clear of the housing.
    /// Widening adds to BOTH gutters, so a shortfall costs twice its size.
    public func widthNeeded(for demand: CGFloat) -> CGFloat {
        guard demand > clearGutter else { return panelWidth }
        return panelWidth + (demand - clearGutter) * 2
    }
}
