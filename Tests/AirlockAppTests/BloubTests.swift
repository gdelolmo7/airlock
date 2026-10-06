import XCTest
import SwiftUI
@testable import AirlockApp
@testable import AirlockCore

/// The bloub's pure surface. What is worth guarding here is not "does it draw"
/// — that needs eyes — but the invariants a future edit can break silently:
/// the precomputed bounds that every draw scales by, the totality of the status
/// mapping, and the product rule that `.angry` is never reachable from a status.
final class BloubTests: XCTestCase {

    /// `SessionStatus` is not `CaseIterable` and this does not add the
    /// conformance to Core just to iterate in a test. The real guard against a
    /// new status going unmapped is the exhaustive switch in
    /// `BloubExpression.init(for:)`, which fails to compile — a stronger check
    /// than anything asserted here.
    private static let allStatuses: [SessionStatus] = [
        .starting, .running, .needsAttention, .waitingQuestion, .idle, .done, .error,
    ]

    // MARK: - Geometry

    /// The mark fills the frame it is handed on its long axis, and is centred on
    /// the other. This is what `BloubBody.bounds` exists to deliver, so it fails
    /// if bounds ever stops being the curve's true extent — the bug that shipped
    /// in the first draft, where bounds held the control-point extents and every
    /// instance drew ~13% short and off-centre while looking about right.
    func testTheMarkFillsTheFrameItIsGiven() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 200)
        let drawn = BloubBody().path(in: frame).boundingRect
        let ratio = BloubBody.bounds.height / BloubBody.bounds.width
        XCTAssertGreaterThan(BloubBody.bounds.width, BloubBody.bounds.height,
                             "the bloub is wider than it is tall; fix the axis below if that changed")
        XCTAssertEqual(drawn.width, frame.width, accuracy: 1)
        XCTAssertEqual(drawn.height, frame.height * ratio, accuracy: 1)
        XCTAssertEqual(drawn.midX, frame.midX, accuracy: 1)
        XCTAssertEqual(drawn.midY, frame.midY, accuracy: 1)
    }

    /// The body must not spill outside the rect it is handed. It renders small in
    /// a panel; a shape that overdraws its frame clips against the container
    /// rather than looking wrong, so nothing downstream would report it.
    func testBodyStaysInsideItsRect() {
        for side in [18.0, 22.0, 34.0, 240.0] {
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            let box = BloubBody().path(in: rect).boundingRect
            XCTAssertTrue(rect.insetBy(dx: -0.5, dy: -0.5).contains(box),
                          "body escaped a \(side)pt frame: \(box)")
        }
    }

    /// Every eye sits wholly inside the silhouette — the invariant that lets
    /// `BloubEyes` skip clipping to the body. The source draws the eyes through a
    /// mask, which would trim an overhanging one; none of them overhangs,
    /// so the clip was dropped. If a hand-added expression pushes an eye past the
    /// outline this fails, and the fix is to restore the intersection rather than
    /// to relax the test.
    func testEveryExpressionKeepsItsEyesInsideTheSilhouette() {
        let rect = CGRect(x: 0, y: 0, width: 400, height: 400)
        let body = BloubBody().path(in: rect)
        let fit = BloubBody.fit(in: rect)
        for expression in BloubExpression.allCases {
            for (side, eye) in [("left", expression.eyes.left), ("right", expression.eyes.right)] {
                let box = CGRect(x: -eye.size.width / 2, y: -eye.size.height / 2,
                                 width: eye.size.width, height: eye.size.height)
                let raw = Path(roundedRect: box,
                               cornerRadius: min(box.width, box.height) / 2,
                               style: .circular)
                    .applying(eye.pose.concatenating(fit))
                let bounds = raw.boundingRect
                var sampled = 0
                for i in 0..<24 {
                    for j in 0..<24 {
                        let point = CGPoint(
                            x: bounds.minX + bounds.width * CGFloat(i) / 23,
                            y: bounds.minY + bounds.height * CGFloat(j) / 23)
                        guard raw.contains(point) else { continue }
                        sampled += 1
                        XCTAssertTrue(body.contains(point),
                                      "\(expression) \(side) eye overhangs the body at \(point)")
                    }
                }
                XCTAssertGreaterThan(sampled, 100, "\(expression) \(side) eye barely sampled")
            }
        }
    }

    /// Both eyes are present and distinct. A duplicated row would read as a
    /// one-eyed bloub and pass every other check here.
    func testEyesAreTwoDistinctShapes() {
        for expression in BloubExpression.allCases {
            let (left, right) = expression.eyes
            XCTAssertGreaterThan(left.size.width, 0, "\(expression) left width")
            XCTAssertGreaterThan(left.size.height, 0, "\(expression) left height")
            XCTAssertNotEqual(left.pose.tx, right.pose.tx, accuracy: 1,
                              "\(expression) eyes share an x position")
        }
    }

    /// A degenerate pose collapses an eye to a line or a point.
    func testEveryPoseIsInvertible() {
        for expression in BloubExpression.allCases {
            for (side, eye) in [("left", expression.eyes.left), ("right", expression.eyes.right)] {
                let determinant = eye.pose.a * eye.pose.d - eye.pose.b * eye.pose.c
                XCTAssertGreaterThan(abs(determinant), 0.01,
                                     "\(expression) \(side) pose is degenerate")
            }
        }
    }

    // MARK: - The blink

    /// Interpolation can overshoot past the phase endpoints; the shape clamps so
    /// a negative lid cannot flip an eye inside out mid-blink.
    func testLidNeverInvertsTheEye() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        for lid in [-0.4, 0.0, 0.23, 1.0, 1.2] {
            let box = BloubEyes(expression: .neutral, lid: lid).path(in: rect).boundingRect
            XCTAssertFalse(box.isNull, "lid \(lid) produced a null path")
            XCTAssertGreaterThanOrEqual(box.height, 0, "lid \(lid) inverted the eye")
        }
    }

    /// Shutting the eyes must actually shorten them, or the blink is invisible.
    func testShutEyesAreShorterThanOpenOnes() {
        let rect = CGRect(x: 0, y: 0, width: 200, height: 200)
        let open = BloubEyes(expression: .neutral, lid: 1).path(in: rect).boundingRect
        let shut = BloubEyes(expression: .neutral, lid: 0.23).path(in: rect).boundingRect
        XCTAssertLessThan(shut.height, open.height * 0.5)
    }

    /// The blink cadence, guarded because its failure mode is invisible to every
    /// other test here: a still frame is correct at every point of the cycle, so
    /// only the ratio between waiting and moving says whether it reads as a blink
    /// or as a fault light. It shipped once at ~80ms a phase.
    func testTheBlinkIsMostlyWaiting() {
        let move = BloubView.closingDuration + BloubView.openingDuration
        XCTAssertGreaterThan(BloubView.betweenDuration, move * 10,
                             "the pause between blinks is no longer dominant")
        XCTAssertGreaterThan(BloubView.betweenDuration, 1.5, "blinking too often to read as idle")
        XCTAssertLessThan(move, 0.4, "a blink this slow reads as a wink")
    }

    // MARK: - The status mapping

    /// Total over the status enum, and stable. If a case is added to
    /// `SessionStatus` this fails to compile in `init(for:)` rather than
    /// defaulting a new state to some arbitrary face.
    func testMappingCoversEveryStatus() {
        let expected: [SessionStatus: BloubExpression] = [
            .idle: .sleepy,
            .starting: .attentive,
            .running: .attentive,
            .needsAttention: .attentive,
            .waitingQuestion: .attentive,
            .done: .happy,
            .error: .confused,
        ]
        for (status, face) in expected {
            XCTAssertEqual(BloubExpression(for: status), face, "\(status)")
        }
    }

    /// The documented product rule: a tool that looks annoyed at its user is a
    /// mis-signal, so no status resolves to `.angry`. Errors get `.confused`.
    func testNoStatusMakesTheBloubAngry() {
        let faces = Self.allStatuses.map(BloubExpression.init(for:))
        XCTAssertFalse(faces.contains(BloubExpression.angry))
        XCTAssertEqual(BloubExpression(for: .error), .confused)
    }

    /// Four faces across seven statuses — the compression is the design, so a
    /// drift back toward one-face-per-status should be a deliberate edit here.
    func testSevenStatusesResolveToFourFaces() {
        XCTAssertEqual(Set(Self.allStatuses.map(BloubExpression.init(for:))).count, 4)
    }

    /// The gate is deliberately not a distinct face: its urgency already has the
    /// warm lamp and a panel that opens itself.
    func testGateLooksTheSameAsPlainWork() {
        XCTAssertEqual(BloubExpression(for: .needsAttention), BloubExpression(for: .running))
        XCTAssertEqual(BloubExpression(for: .waitingQuestion), BloubExpression(for: .running))
    }
}

/// The menu bar mark. Its failure mode is specific and silent: a template image
/// carries one colour plus alpha, so if the eye knockout is ever "simplified"
/// into a fill, the eyes stop existing the moment macOS tints the image — and
/// nothing crashes, nothing warns, the glyph just goes blank in the menu bar.
final class StatusMarkTests: XCTestCase {

    /// Rasterise the real image the status item is handed, then read alpha where
    /// the eyes should be holes and where the body should be solid.
    @MainActor func testEyesAreKnockedOutNotFilled() throws {
        let mark = AppDelegate.statusMarkForPreview()
        XCTAssertTrue(mark.isTemplate, "a non-template mark will not tint with the menu bar")

        let side: CGFloat = 120
        let canvas = NSImage(size: NSSize(width: side, height: side))
        canvas.lockFocus()
        mark.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        canvas.unlockFocus()
        let rep = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(canvas.tiffRepresentation)))

        // Eye centres derived from the same data the drawing uses, so this keeps
        // working if a pose moves. `NSBitmapImageRep` is top-left origin, which
        // matches the source artwork's y-down space.
        let fit = BloubBody.fit(in: CGRect(x: 0, y: 0, width: side, height: side))
        let scale = CGFloat(rep.pixelsWide) / side
        for (name, eye) in [("left", BloubExpression.attentive.eyes.left),
                            ("right", BloubExpression.attentive.eyes.right)] {
            let centre = CGPoint.zero.applying(eye.pose).applying(fit)
            let colour = try XCTUnwrap(rep.colorAt(x: Int(centre.x * scale),
                                                   y: Int(centre.y * scale)))
            XCTAssertLessThan(colour.alphaComponent, 0.5,
                              "\(name) eye is filled, not knocked out — it will vanish when tinted")
        }

        // And the body around them is solid, so the above is a hole rather than
        // the whole mark having failed to draw.
        let body = CGPoint(x: 0, y: 55).applying(fit)
        let solid = try XCTUnwrap(rep.colorAt(x: Int(body.x * scale), y: Int(body.y * scale)))
        XCTAssertGreaterThan(solid.alphaComponent, 0.9, "the mark's body did not draw")
    }
}
