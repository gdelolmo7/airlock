import AppKit
import SwiftUI
import XCTest
import AirlockCore
@testable import AirlockApp

/// How smoothly a real call's transcript scrolls in the notes window: it is
/// scrolled top to bottom, 30 points at a time, and each step is timed.
///
/// Skipped unless `AIRLOCK_SCROLL_BENCH` names a call's folder (a copy, not
/// the one in `~/Airlock/Meetings`), because it needs a long call to say
/// anything and a number to be read by a person, not a pass. A frame is
/// 8.3 ms on a 120 Hz screen; the steps over it are what the hand feels.
///
/// It found the transcript asking every turn as it scrolled in whether the
/// call's voices can be named, which reads every line of the call: a
/// 73-minute call took longer than a frame on 429 steps of 979, and on 1
/// once it was asked once.
///
///     AIRLOCK_SCROLL_BENCH=/path/to/copy swift test --filter TranscriptScrollBench
@MainActor
final class TranscriptScrollBench: XCTestCase {
    func testScrollingALongTranscript() throws {
        guard let path = ProcessInfo.processInfo.environment["AIRLOCK_SCROLL_BENCH"] else {
            throw XCTSkip("Set AIRLOCK_SCROLL_BENCH to a call's folder to time its transcript")
        }
        let folder = URL(fileURLWithPath: path)
        let store = MeetingStore(root: folder.deletingLastPathComponent())
        let record = try XCTUnwrap(store.loadRecord(in: folder), "no meeting.json in \(path)")
        let call = CallNotesLibrary.Call(folder: folder, record: record, page: store.notesPage(in: folder))
        let library = CallNotesLibrary(previewing: [call], tab: .transcript)
        library.selection = call.id

        _ = NSApplication.shared
        let host = NSHostingView(rootView: CallNotesView().environment(library))
        // Off every screen: drawn and laid out, never seen.
        let window = NSWindow(contentRect: NSRect(x: -12_000, y: -12_000, width: 1000, height: 760),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        settle(host)

        // The transcript's is the tallest; the list of calls is the other.
        let scroll = try XCTUnwrap(Self.scrollViews(in: host).max {
            ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0)
        })
        var steps: [Double] = []
        var y: CGFloat = 0
        while steps.count < 10_000 {
            let bottom = max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
            guard y < bottom else { break }
            y = min(bottom, y + 30)
            let started = CACurrentMediaTime()
            scroll.contentView.scroll(to: NSPoint(x: 0, y: y))
            scroll.reflectScrolledClipView(scroll.contentView)
            settle(host)
            steps.append((CACurrentMediaTime() - started) * 1000)
        }

        let sorted = steps.sorted()
        func at(_ share: Double) -> Double { sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
        XCTAssertFalse(sorted.isEmpty, "the transcript did not scroll")
        guard !sorted.isEmpty else { return }
        print(String(format: "transcript scroll: %d lines, %d steps, %.2f s in all; "
                         + "middle %.2f ms, 90%% %.2f ms, 99%% %.2f ms, slowest %.2f ms; "
                         + "over a 120 Hz frame %d, over a 60 Hz frame %d",
                     record.segments.count, steps.count, steps.reduce(0, +) / 1000,
                     at(0.5), at(0.9), at(0.99), sorted.last ?? 0,
                     steps.filter { $0 > 8.3 }.count, steps.filter { $0 > 16.7 }.count))
    }

    /// What one frame of scrolling costs: the update SwiftUI schedules on
    /// the run loop, then layout and drawing.
    private func settle(_ host: NSView) {
        for _ in 0..<3 { CFRunLoopRunInMode(.defaultMode, 0, true) }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        CATransaction.flush()
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        ((view as? NSScrollView).map { [$0] } ?? []) + view.subviews.flatMap(scrollViews)
    }
}
