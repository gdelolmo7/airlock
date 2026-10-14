import CryptoKit
import SwiftUI
import XCTest
@testable import AirlockApp
@testable import AirlockCore

/// The purchase window as it is reached: from a button that names a plan, on
/// a day with its own counts, and after a key that may arrive from Settings
/// rather than the browser.
///
/// Each of these was wrong once. The monthly button opened on yearly, a second
/// open showed the first open's figures, and a key pasted in Settings left the
/// window waiting for a browser that had nothing more to say.
@MainActor
final class PurchaseWindowTests: XCTestCase {

    // MARK: - The plan it opens on

    func testTheLastDayCardsPriceButtonsOpenOnTheirOwnPlan() {
        let offers = LastDayCard.offers
        XCTAssertEqual(offers.map(\.plan), [.yearly, .monthly])
        for offer in offers {
            XCTAssertTrue(offer.title.contains(offer.plan.price),
                          "\"\(offer.title)\" opens on \(offer.plan) at \(offer.plan.price)")
        }
    }

    func testAskingToBuyPassesThePlanThrough() {
        let license = LicenseModel(previewing: .trialing(daysRemaining: 1))
        var opened: [License.Period] = []
        license.onShowPurchase = { opened.append($0) }

        license.showPurchase(plan: .monthly)
        license.showPurchase()

        XCTAssertEqual(opened, [.monthly, .yearly], "every other way in keeps yearly")
    }

    func testThePlanItOpensOnIsYearlyUnlessSaid() {
        let view = PurchaseView(flow: PurchaseFlow(), tally: UsageTally(),
                                onBuy: { _ in }, onPasteKey: {}, onDismiss: {})
        XCTAssertEqual(view.openingPlan, .yearly)
    }

    func testTheWindowOpensOnThePlanItWasAskedFor() {
        let controller = makeController(flow: PurchaseFlow())

        controller.prepare(plan: .monthly)
        XCTAssertEqual(controller.hosting?.rootView.openingPlan, .monthly)

        // Not remembered: the next way in that names nothing is yearly again.
        controller.prepare(plan: .yearly)
        XCTAssertEqual(controller.hosting?.rootView.openingPlan, .yearly)
    }

    // MARK: - Today's figures

    func testEveryOpenReadsTodaysCountsAndRequest() {
        var approvals = 41
        var gate: String? = "git push origin main"
        let controller = makeController(flow: PurchaseFlow(),
                                        tally: { UsageTally(approvals: approvals) },
                                        pendingGate: { gate })

        controller.prepare(plan: .yearly)
        let first = controller.hosting
        XCTAssertEqual(first?.rootView.tally.approvals, 41)
        XCTAssertEqual(first?.rootView.pendingGate, "git push origin main")

        approvals = 58
        gate = nil
        controller.prepare(plan: .yearly)

        XCTAssertFalse(controller.hosting === first, "a new view, so nothing of the last open survives")
        XCTAssertEqual(controller.hosting?.rootView.tally.approvals, 58)
        XCTAssertNil(controller.hosting?.rootView.pendingGate, "that request was answered since")
    }

    /// A purchase that went through some other day is not what somebody
    /// opening the window to subscribe again should read.
    func testAnOldSuccessDoesNotGreetTheNextOpen() {
        let flow = PurchaseFlow()
        flow.begin(plan: .yearly)
        flow.succeed()

        makeController(flow: flow).prepare(plan: .yearly)

        XCTAssertEqual(flow.stage, .idle)
    }

    /// Closing the window cancels nothing, and opening it again must not either.
    func testReopeningMidPaymentKeepsWaiting() {
        let flow = PurchaseFlow()
        flow.begin(plan: .monthly)

        makeController(flow: flow).prepare(plan: .yearly)

        XCTAssertTrue(flow.isWaiting)
        XCTAssertEqual(flow.plan, .monthly)
    }

    // MARK: - A key from anywhere

    func testAKeyPastedAnywhereEndsTheWaiting() {
        for stalled in [false, true] {
            let flow = PurchaseFlow()
            var gate: String? = nil
            let controller = makeController(flow: flow, pendingGate: { gate })
            controller.prepare(plan: .yearly)
            flow.begin(plan: .yearly)
            if stalled { flow.setStalled() }

            gate = "npm publish"
            controller.licenceApplied()

            XCTAssertEqual(flow.stage, .activated)
            XCTAssertEqual(controller.hosting?.rootView.pendingGate, "npm publish",
                           "the request handed back is the one waiting now")
        }
    }

    func testEverySuccessfulPasteIsAnnouncedAndNoRefusalIs() async {
        let issuer = Curve25519.Signing.PrivateKey()
        let suite = "PurchaseWindowTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let license = LicenseModel(previewing: .trialExpired,
                                   checkingWith: issuer.publicKey.rawRepresentation,
                                   keepingIn: defaults)
        var announced = 0
        license.onApplied = { announced += 1 }

        let refused = await license.apply(token(signedBy: Curve25519.Signing.PrivateKey()))
        XCTAssertFalse(refused)
        XCTAssertEqual(announced, 0, "a key that did not verify leaves the window waiting")

        let accepted = await license.apply(token(signedBy: issuer))
        XCTAssertTrue(accepted)
        XCTAssertEqual(announced, 1)
    }

    // MARK: - What the waiting screen promises

    /// It promised the window would fill itself in and nothing need be copied.
    /// That rests on the browser handing the key back; the email always comes.
    func testTheWaitingNoteSaysWhereTheKeyIsIfTheWindowStaysPut() {
        // Read as it is seen: the place is held on one line with no-break spaces.
        let note = PurchaseView.waitingNote.replacingOccurrences(of: "\u{00A0}", with: " ")
        XCTAssertTrue(note.contains("email"))
        XCTAssertTrue(note.contains("Settings › Licence"))
        XCTAssertFalse(note.contains("don't need to copy"))
    }

    // MARK: - The look

    func testTheCloudSaysHowItIsGoing() {
        XCTAssertEqual(PurchaseView.face(for: .idle).expression, .curious)

        let done = PurchaseView.face(for: .activated)
        XCTAssertEqual(done.expression, .happy, "the cloud says it, where a green tick did")
        XCTAssertEqual(done.tint, .done)

        let failed = PurchaseView.face(for: .couldNotOpen)
        XCTAssertTrue([.scared, .confused].contains(failed.expression), "worried, not cheerful")
        XCTAssertLessThan(PurchaseView.cloudWidth(for: .couldNotOpen), PurchaseView.cloudWidth(for: .idle),
                          "and small: nothing was charged")
    }

    /// Five screens, five faces, and only the finish hops. Nothing is dimmed:
    /// an accent turned down over black is a colour that is not in the palette.
    func testEveryScreenHasItsOwnFaceAndOnlyTheFinishCelebrates() {
        let stages: [PurchaseFlow.Stage] = [.idle, .waiting(since: Date()), .stalled, .couldNotOpen, .activated]
        let faces = stages.map(PurchaseView.face(for:))

        for (index, face) in faces.enumerated() {
            XCTAssertFalse(face.isDimmed, "\(stages[index])")
            XCTAssertEqual(face.celebrates, stages[index] == .activated, "\(stages[index])")
            for other in faces[(index + 1)...] { XCTAssertNotEqual(face, other) }
        }
    }

    func testTheWindowWearsSettingsChrome() throws {
        let controller = makeController(flow: PurchaseFlow())
        controller.prepare(plan: .yearly)
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.styleMask.contains(.fullSizeContentView))
        XCTAssertTrue(window.titlebarAppearsTransparent)
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(window.appearance?.name, .darkAqua)
    }

    /// The page runs up under a see-through title bar now, so the window has
    /// to be the page plus the bar, or the buttons at the bottom are the first
    /// thing cut off. It is sized two ways: by `prepare` on every open, and by
    /// the hosting view's own constraints for a screen reached while it is up.
    func testEveryScreenFitsUnderTheTitleBar() {
        let opened: [(String, (PurchaseFlow) -> Void)] = [
            ("offer", { _ in }),
            ("waiting", { $0.begin(plan: .yearly) }),
            ("stalled", { $0.begin(plan: .yearly); $0.setStalled() }),
        ]
        for (name, setup) in opened {
            let flow = PurchaseFlow()
            setup(flow)
            let controller = makeController(flow: flow, tally: { UsageTally(approvals: 41, answers: 9) })
            controller.prepare(plan: .yearly)
            assertFits(controller, name)
        }

        let reached: [(String, (PurchaseFlow, PurchaseWindowController) -> Void)] = [
            ("couldNotOpen", { flow, _ in flow.failToOpen(plan: .yearly) }),
            ("activated", { flow, controller in flow.begin(plan: .yearly); controller.licenceApplied() }),
        ]
        for (name, reach) in reached {
            let flow = PurchaseFlow()
            let controller = makeController(flow: flow, pendingGate: { "git push origin main" })
            controller.prepare(plan: .yearly)
            reach(flow, controller)
            // The pass a window on screen gets on its own.
            controller.hosting?.view.layoutSubtreeIfNeeded()
            controller.window?.updateConstraintsIfNeeded()
            controller.window?.layoutIfNeeded()
            assertFits(controller, name)
        }
    }

    // MARK: - Fixtures

    /// The area under the title bar is exactly the page, measured on its own
    /// with no window and so no bar.
    private func assertFits(_ controller: PurchaseWindowController, _ name: String, line: UInt = #line) {
        guard let window = controller.window else { return XCTFail("no window for \(name)", line: line) }
        let page = NSHostingView(rootView: controller.makeView(plan: .yearly)).fittingSize
        XCTAssertEqual(window.contentLayoutRect.height, page.height, accuracy: 0.5, name, line: line)
        XCTAssertEqual(window.contentLayoutRect.width, page.width, accuracy: 0.5, name, line: line)
    }

    private func makeController(flow: PurchaseFlow,
                                tally: @escaping () -> UsageTally = { UsageTally() },
                                pendingGate: @escaping () -> String? = { nil }) -> PurchaseWindowController {
        PurchaseWindowController(flow: flow, license: LicenseModel(previewing: .trialExpired),
                                 tally: tally, pendingGate: pendingGate, openKeyField: {})
    }

    /// Signed the way the licence server signs, with no machine named, so it
    /// is good on any Mac.
    private func token(signedBy key: Curve25519.Signing.PrivateKey) -> String {
        let now = Date()
        let license = License(id: "lic_test", email: "someone@example.com", product: "airlock",
                              period: .monthly, issued: now,
                              renewsAt: now.addingTimeInterval(30 * 86_400),
                              checkBy: now.addingTimeInterval(44 * 86_400))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let payload = try! encoder.encode(license)
        let signature = try! key.signature(for: payload)
        return "\(LicenseVerifier.encode(payload)).\(LicenseVerifier.encode(signature))"
    }
}
