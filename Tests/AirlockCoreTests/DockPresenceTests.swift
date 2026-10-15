import XCTest
@testable import AirlockCore

final class DockPresenceTests: XCTestCase {
    private typealias Tracked = DockPresence.Tracked<String>

    // MARK: - Which policy

    func testNothingOpenIsJustTheNotch() {
        XCTAssertEqual(DockPresence.policy([]), .accessory)
        XCTAssertEqual(DockPresence.policy([.closed, .closed]), .accessory)
    }

    func testAnOpenWindowMakesAnOrdinaryApp() {
        XCTAssertEqual(DockPresence.policy([.onScreen]), .regular)
        XCTAssertEqual(DockPresence.policy([.closed, .onScreen]), .regular)
    }

    /// Minimised still counts: without the Dock icon there would be nothing
    /// to click to get it back.
    func testAMinimisedWindowKeepsTheDockIcon() {
        XCTAssertEqual(DockPresence.policy([.minimised]), .regular)
        XCTAssertEqual(DockPresence.policy([.closed, .minimised]), .regular)
    }

    // MARK: - What the Dock icon brings back

    /// The notch panel can take the keyboard as well, so a click on the Dock
    /// icon names the window to give it to.
    func testAWindowOnScreenComesFirst() {
        let windows = [Tracked(id: "notes", state: .onScreen, lastUsed: 1),
                       Tracked(id: "settings", state: .minimised, lastUsed: 2)]
        XCTAssertEqual(DockPresence.reopenTarget(windows), "notes")
    }

    func testTheWindowUsedLastComesFirst() {
        let windows = [Tracked(id: "notes", state: .onScreen, lastUsed: 4),
                       Tracked(id: "settings", state: .onScreen, lastUsed: 2)]
        XCTAssertEqual(DockPresence.reopenTarget(windows), "notes")
    }

    func testTheMostRecentMinimisedWindowComesBack() {
        let windows = [Tracked(id: "notes", state: .minimised, lastUsed: 3),
                       Tracked(id: "settings", state: .minimised, lastUsed: 1),
                       Tracked(id: "purchase", state: .closed, lastUsed: 5)]
        XCTAssertEqual(DockPresence.reopenTarget(windows), "notes")
    }

    /// A relaunch from Finder or Spotlight with nothing open asks for
    /// nothing in particular: no window appears.
    func testNothingOpenBringsNothingBack() {
        XCTAssertNil(DockPresence.reopenTarget([Tracked]()))
        XCTAssertNil(DockPresence.reopenTarget([Tracked(id: "notes", state: .closed, lastUsed: 1)]))
    }

    // MARK: - Focus on the way back

    func testFocusGoesBackOnlyWhenLeavingWhileInFront() {
        XCTAssertTrue(DockPresence.handsFocusBack(from: .regular, to: .accessory, isActive: true))
        XCTAssertFalse(DockPresence.handsFocusBack(from: .regular, to: .accessory, isActive: false))
        XCTAssertFalse(DockPresence.handsFocusBack(from: .regular, to: .regular, isActive: true))
        XCTAssertFalse(DockPresence.handsFocusBack(from: .accessory, to: .accessory, isActive: true))
        XCTAssertFalse(DockPresence.handsFocusBack(from: .accessory, to: .regular, isActive: true))
    }

    // MARK: - The menu bar on the way in

    func testTheMenuBarIsHandedOverOnlyWhenAlreadyActive() {
        XCTAssertTrue(DockPresence.redrawsMenuBar(from: .accessory, to: .regular, wasActive: true))
        XCTAssertFalse(DockPresence.redrawsMenuBar(from: .accessory, to: .regular, wasActive: false))
        XCTAssertFalse(DockPresence.redrawsMenuBar(from: .regular, to: .regular, wasActive: true))
        XCTAssertFalse(DockPresence.redrawsMenuBar(from: .regular, to: .accessory, wasActive: true))
    }
}
