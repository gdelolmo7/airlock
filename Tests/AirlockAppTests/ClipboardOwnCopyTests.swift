import AirlockCore
import AirlockTestSupport
import AppKit
import XCTest
@testable import AirlockApp

/// Copies made inside Airlock reach the clipboard history like any other.
///
/// They didn't. The history skipped every change while Airlock was the app in
/// front, so Copy in a past call's notes window put the notes on the clipboard
/// and nowhere in the list. And from the notch, which is never in front, a copy
/// was credited to whatever app was.
///
/// Each test writes to a pasteboard of its own, never the one the person is
/// using, and keeps the history files in a scratch folder: a kept copy prunes
/// the image folder, which must never be the real one.
@MainActor
final class ClipboardOwnCopyTests: XCTestCase {
    private var sandbox: TestScratch!
    private var pasteboard: NSPasteboard!

    override func setUp() {
        super.setUp()
        sandbox = TestScratch("airlock-own-copy")
        setenv("AIRLOCK_STATE_HOME", sandbox.root.path, 1)
        pasteboard = NSPasteboard.withUniqueName()
    }

    override func tearDown() {
        AirlockCopy.history = nil
        pasteboard.releaseGlobally()
        unsetenv("AIRLOCK_STATE_HOME")
        sandbox.remove()
        super.tearDown()
    }

    private func item(_ text: String) -> ClipboardItem {
        ClipboardItem(payload: .text(text), fingerprint: ClipboardItem.fingerprint(forText: text),
                      copiedAt: Date(timeIntervalSince1970: 0))
    }

    private func model(_ texts: [String] = [],
                       frontmost: @escaping @MainActor () -> NSRunningApplication? = { nil })
        -> ClipboardWidgetModel {
        ClipboardWidgetModel(history: ClipboardHistory(items: texts.map(item)),
                             pasteboard: pasteboard, frontmostApp: frontmost)
    }

    private func texts(_ clipboard: ClipboardWidgetModel) -> [String] {
        clipboard.history.items.compactMap(\.text)
    }

    // MARK: - Through the door

    func testAnAirlockCopyIsRowOneCreditedToAirlock() throws {
        let clipboard = model(["something older"])
        AirlockCopy.history = clipboard

        AirlockCopy.put("The call's notes")

        XCTAssertEqual(pasteboard.string(forType: .string), "The call's notes")
        XCTAssertEqual(texts(clipboard), ["The call's notes", "something older"])
        let first = try XCTUnwrap(clipboard.history.items.first)
        XCTAssertEqual(first.sourceBundleID, NSRunningApplication.current.bundleIdentifier)
        XCTAssertEqual(first.sourceAppName, NSRunningApplication.current.localizedName)
    }

    /// The door claims the change, so the next tick does not keep it again
    /// under the name of whatever app is in front.
    func testTheNextPollDoesNotKeepItTwice() {
        let clipboard = model(frontmost: { nil })
        AirlockCopy.history = clipboard

        AirlockCopy.put("Copied once")
        clipboard.poll()

        XCTAssertEqual(texts(clipboard), ["Copied once"])
    }

    /// Too big for the history is too big from Airlock too: still on the
    /// clipboard, and the clipboard tab says why it isn't in the list.
    func testATooLargeCopyIsOnTheClipboardButNotKept() {
        let clipboard = model(["something older"])
        let huge = String(repeating: "a", count: ClipboardLimits.maximumTextBytes + 1)

        clipboard.keepOwnCopy(huge)

        XCTAssertEqual(pasteboard.string(forType: .string)?.count, huge.count)
        XCTAssertEqual(texts(clipboard), ["something older"])
        XCTAssertEqual(clipboard.lastSkip, .tooLarge(bytes: huge.utf8.count))
    }

    // MARK: - The poll

    /// ⌘C in a past call's notes or in Settings, with Airlock in front. This
    /// is the change the history used to skip.
    func testACopyWhileAirlockIsInFrontIsKept() {
        let clipboard = model(["something older"], frontmost: { NSRunningApplication.current })

        pasteboard.clearContents()
        pasteboard.setString("Selected in the notes window", forType: .string)
        clipboard.poll()

        XCTAssertEqual(texts(clipboard), ["Selected in the notes window", "something older"])
        XCTAssertEqual(clipboard.history.items.first?.sourceBundleID,
                       NSRunningApplication.current.bundleIdentifier)
    }

    /// Picking a row writes it back and must not come back as a new copy: the
    /// list would reshuffle under the pointer.
    func testPickingARowIsNotKeptAgain() throws {
        let clipboard = model(["alpha", "beta"], frontmost: { NSRunningApplication.current })
        let beta = try XCTUnwrap(clipboard.history.items.first { $0.text == "beta" })

        XCTAssertTrue(clipboard.copy(beta))
        clipboard.poll()

        XCTAssertEqual(pasteboard.string(forType: .string), "beta")
        XCTAssertEqual(texts(clipboard), ["alpha", "beta"])
    }

    // MARK: - The notes window

    func testCopyInAPastCallsNotesIsRowOne() {
        let clipboard = model(["something older"])
        AirlockCopy.history = clipboard
        let call = Self.call(page: "# Weekly sync\n\n- Ship on Friday")
        let library = CallNotesLibrary(previewing: [call], tab: .notes)

        library.copy(call)

        XCTAssertEqual(texts(clipboard).first, "# Weekly sync\n\n- Ship on Friday")
        XCTAssertTrue(library.justCopied(call))
    }

    func testCopyOnTheTranscriptTabIsRowOne() throws {
        let clipboard = model()
        AirlockCopy.history = clipboard
        let call = Self.call(page: "The notes", said: "Shall we ship on Friday?")
        let library = CallNotesLibrary(previewing: [call], tab: .transcript)

        library.copy(call)

        let first = try XCTUnwrap(texts(clipboard).first)
        XCTAssertTrue(first.contains("Shall we ship on Friday?"), first)
        XCTAssertFalse(first.contains("The notes"), "the transcript tab copies the transcript")
    }

    /// A made-up call held in memory, read from no folder.
    private static func call(page: String?, said: String? = nil) -> CallNotesLibrary.Call {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        let record = MeetingRecord(bundleID: "us.zoom.xos", appName: "Zoom", startedAt: start,
                                   endedAt: start.addingTimeInterval(1_800),
                                   segments: said.map { [MeetingSegment(speaker: .them, start: 1, end: 4, text: $0)] } ?? [],
                                   event: MeetingEvent(title: "Weekly sync", start: start))
        return CallNotesLibrary.Call(folder: URL(fileURLWithPath: "/var/empty/weekly-sync"),
                                     record: record, page: page)
    }
}
