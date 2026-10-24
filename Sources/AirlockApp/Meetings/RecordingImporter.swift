import AVFoundation
import AirlockCore
import AppKit
import IOKit.pwr_mgt
import UniformTypeIdentifiers

/// "Add a recording": a sound file somebody already has (a voice memo, a
/// WhatsApp voice note), read into a new meeting with the same notes as one
/// heard in the room (`RecordingReader`). From the notes window's button or a
/// file dropped on it, the Calls tab and the menu bar.
///
/// One at a time: while one is read the buttons are greyed and drops are
/// refused. Where it is (`reading`) is kept in memory only, so a reading the
/// app quits during is gone at the next launch, its half-made meeting with it
/// (`MeetingNotesModel.start`). The file itself is never touched.
@MainActor
@Observable
final class RecordingImporter {
    /// The recording being read, for the window and the Calls tab.
    struct Reading: Equatable {
        var progress: RecordingImport.Progress
        /// The meeting's folder, once it is made: the window lists it then.
        var folder: URL?
        /// When the meeting began, once the file is open.
        var startedAt: Date?
        /// The last lines written down, oldest first: "Heard so far".
        var lines: [MeetingSegment] = []
        /// "Stop" was pressed and the reading is winding down.
        var stopping = false
    }

    private(set) var reading: Reading?

    /// The meeting is made and saved, before any listening: the window opens
    /// on it.
    @ObservationIgnored var onFolder: ((URL) -> Void)?
    /// The notes are saved.
    @ObservationIgnored var onSaved: ((URL, MeetingRecord, MeetingNotes?) -> Void)?
    /// A reading is over, however it ended: lists read again.
    @ObservationIgnored var onEnded: (() -> Void)?

    @ObservationIgnored private var reader: RecordingReader?
    @ObservationIgnored private var awake: IOPMAssertionID?
    @ObservationIgnored private let previewing: Bool
    @ObservationIgnored private let log: (String) -> Void = { MeetingDiagnostics.log($0) }

    init() {
        previewing = false
    }

    /// Standing in `reading` and reading nothing, for the state gallery.
    init(previewing reading: Reading?) {
        self.reading = reading
        previewing = true
    }

    var isBusy: Bool { reading != nil }

    /// Whether a file dropped now would be read: a sound file, and nothing
    /// being read already.
    func takes(_ url: URL) -> Bool {
        !isBusy && RecordingImport.isSound(url)
    }

    /// Asks which recording, then reads it.
    func choose() {
        guard !isBusy, !previewing else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Add a Recording")
        panel.message = String(localized: "Pick a recording to get notes from. The file stays where it is, and nothing leaves your Mac.")
        panel.prompt = String(localized: "Get Notes")
        panel.allowedContentTypes = Self.contentTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        // A menu bar app is not in front: the panel would open behind.
        NSApp.activate(ignoringOtherApps: true)
        Task { [weak self] in
            guard await panel.begin() == .OK, let url = panel.url else { return }
            self?.add(url)
        }
    }

    /// Reads `url` into a new meeting.
    func add(_ url: URL) {
        guard !isBusy, !previewing else { return }
        let reader = RecordingReader(log: log)
        self.reader = reader
        reading = Reading(progress: RecordingImport.Progress(fileName: url.lastPathComponent, seconds: 0))
        reader.onProgress = { [weak self] progress in self?.reading?.progress = progress }
        reader.onFolder = { [weak self] folder, record in
            self?.reading?.folder = folder
            self?.reading?.startedAt = record.startedAt
            self?.onFolder?(folder)
        }
        reader.onLines = { [weak self] lines in self?.reading?.lines = lines }
        holdAwake()
        log("recording: added (\(url.pathExtension.lowercased()))")
        Task { [weak self] in
            let outcome = await reader.read(url)
            guard let self else { return }
            self.reader = nil
            releaseAwake()
            if case let .saved(folder, record, notes) = outcome { onSaved?(folder, record, notes) }
            reading = nil
            onEnded?()
            if case let .failed(reason) = outcome { Self.tell(reason) }
        }
    }

    /// "Stop": the reading ends and its meeting goes. The file is untouched.
    func stop() {
        guard let reader, reading?.stopping == false else { return }
        log("recording: stop pressed")
        reading?.stopping = true
        reader.stop()
    }

    /// The recording's length, for the chip on a file being dragged in. Nil
    /// when it can't be read as sound.
    nonisolated static func length(of url: URL) async -> TimeInterval? {
        await Task.detached(priority: .userInitiated) { () -> TimeInterval? in
            guard let file = try? AVAudioFile(forReading: url), file.processingFormat.sampleRate > 0 else { return nil }
            return Double(file.length) / file.processingFormat.sampleRate
        }.value
    }

    /// What the open panel offers: any sound, and the files a phone or a chat
    /// app saves by their extension, video among them.
    private static var contentTypes: [UTType] {
        [.audio] + RecordingImport.soundExtensions.sorted().compactMap { UTType(filenameExtension: $0) }
    }

    private static func tell(_ reason: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn\u{2019}t get notes from this recording")
        alert.informativeText = reason
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    /// A long recording takes minutes: the Mac stays awake for them, as it
    /// does while notes are taken in the room.
    private func holdAwake() {
        guard awake == nil else { return }
        var assertion = IOPMAssertionID(0)
        let result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleSystemSleep as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
            "Airlock — getting notes from a recording" as CFString, &assertion)
        awake = result == kIOReturnSuccess ? assertion : nil
        log(result == kIOReturnSuccess ? "recording: awake held" : "recording: awake FAILED (\(result))")
    }

    private func releaseAwake() {
        guard let awake else { return }
        IOPMAssertionRelease(awake)
        self.awake = nil
    }
}
