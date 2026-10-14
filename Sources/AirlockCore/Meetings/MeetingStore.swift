import Foundation

/// Reads and writes a call's folder under `~/Airlock/Meetings/`.
///
/// Every file is written whole and atomically, and readable only by you
/// (0600, folders 0700): what was said on a call is at least as private as
/// what is on the clipboard. `AIRLOCK_WORKSPACE` moves the root, for tests.
public struct MeetingStore: Sendable {
    public let root: URL

    public init(root: URL = WorkspaceLayout.resolve().meetings) {
        self.root = root
    }

    /// A new folder for a call, never one that already exists: two calls in
    /// the same minute in the same app get "… 2".
    public func makeFolder(for record: MeetingRecord, timeZone: TimeZone = .current) throws -> URL {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let existing = Set((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
        let name = WorkspaceLayout.uniqueName(for: MeetingFiles.folderName(for: record, timeZone: timeZone),
                                              existing: existing)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: false,
                                    attributes: [.posixPermissions: 0o700])
        return folder
    }

    /// The record and the readable transcript, together. Called after every
    /// new line, so what is on disk is never more than a sentence behind.
    public func saveTranscript(_ record: MeetingRecord, in folder: URL,
                               timeZone: TimeZone = .current) throws {
        try saveRecord(record, in: folder)
        try write(Data(MeetingFiles.transcript(of: record, timeZone: timeZone).utf8),
                  to: folder.appendingPathComponent(MeetingFiles.transcriptName))
    }

    private func saveRecord(_ record: MeetingRecord, in folder: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try write(encoder.encode(record), to: folder.appendingPathComponent(MeetingFiles.recordName))
    }

    /// Who wrote the notes (`MeetingNotesWriter`), put in the record on
    /// disk: the record in hand may be older than names given since.
    public func saveNotesWriter(_ writer: MeetingNotesWriter?, in folder: URL) throws {
        guard var record = loadRecord(in: folder), record.notesWriter != writer else { return }
        record.notesWriter = writer
        try saveRecord(record, in: folder)
    }

    /// The notes page as it is now, kept beside the new one about to take
    /// its place, under a name of its own that is never written over
    /// (`MeetingFiles.earlierNotesName`). Its name, or nil when there were
    /// no notes to keep.
    @discardableResult
    public func keepEarlierNotes(in folder: URL) throws -> String? {
        guard let page = notesPage(in: folder) else { return nil }
        let existing = Set((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        let name = MeetingFiles.earlierNotesName(existing: existing)
        try write(Data(page.utf8), to: folder.appendingPathComponent(name))
        return name
    }

    /// The notes page, and the page as it was written, without the line
    /// that promises they will be written online (`MeetingFiles.offlineLine`).
    public func dropOfflineLine(in folder: URL) throws {
        for name in [Self.notesAsWrittenName, MeetingFiles.notesName] {
            let url = folder.appendingPathComponent(name)
            guard let page = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let kept = MeetingFiles.withoutOfflineLine(page)
            if kept != page { try write(Data(kept.utf8), to: url) }
        }
    }

    /// The notes, with the names given to voices put in (`MeetingNaming`),
    /// from the record on disk rather than any copy of it in hand: names
    /// given while the notes were being written must not be lost. The page
    /// as it was written is kept beside it, hidden, for naming again.
    public func saveNotes(_ page: String, in folder: URL) throws {
        try write(Data(page.utf8), to: folder.appendingPathComponent(Self.notesAsWrittenName))
        let named = loadRecord(in: folder).map { MeetingNaming.apply($0, to: page) } ?? page
        try write(Data(named.utf8), to: folder.appendingPathComponent(MeetingFiles.notesName))
    }

    /// The notes as the model wrote them, before any names were put in.
    public static let notesAsWrittenName = ".Notes as written.md"

    /// Names given after the meeting (`MeetingRecord.name`), saved: the
    /// record, the transcript and the notes all call each voice by its name
    /// from now on. The notes are named again from the page as it was
    /// written; notes from before names existed are that page already.
    public func saveNames(of record: MeetingRecord, in folder: URL,
                          timeZone: TimeZone = .current) throws {
        // A record read before the notes were written has no writer yet:
        // the one on disk is kept.
        var record = record
        if record.notesWriter == nil { record.notesWriter = loadRecord(in: folder)?.notesWriter }
        try saveTranscript(record, in: folder, timeZone: timeZone)
        let kept = folder.appendingPathComponent(Self.notesAsWrittenName)
        let written = (try? String(contentsOf: kept, encoding: .utf8)) ?? notesPage(in: folder)
        guard let written else { return }
        if !FileManager.default.fileExists(atPath: kept.path) {
            try write(Data(written.utf8), to: kept)
        }
        try write(Data(MeetingNaming.apply(record, to: written).utf8),
                  to: folder.appendingPathComponent(MeetingFiles.notesName))
    }

    /// The record in a folder, or nil when it is missing or unreadable.
    public func loadRecord(in folder: URL) -> MeetingRecord? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(MeetingFiles.recordName))
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(MeetingRecord.self, from: data)
    }

    /// What the notes file says, or nil before it is written.
    public func notesPage(in folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent(MeetingFiles.notesName), encoding: .utf8)
    }

    /// The record in a folder while it is kept: nil as well for a call that
    /// ended too short to keep (`MeetingRecord.droppedAt`), whose folder is
    /// on its way out.
    public func keptRecord(in folder: URL) -> MeetingRecord? {
        guard let record = loadRecord(in: folder), record.droppedAt == nil else { return nil }
        return record
    }

    /// Every call that has notes or a transcript, newest first, for the notes
    /// window. A folder without a readable record is not a call's, and one
    /// too short to keep is not listed while it waits to be removed.
    public func calls() -> [(folder: URL, record: MeetingRecord)] {
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return folders.compactMap { folder in keptRecord(in: folder).map { (folder, $0) } }
            .sorted { $0.record.startedAt > $1.record.startedAt }
    }

    /// Removes a call's folder and everything in it. Only ever a folder right
    /// inside the root: anything else is refused, whatever path it is handed.
    public func remove(_ folder: URL) throws {
        let target = folder.standardizedFileURL.resolvingSymlinksInPath()
        guard target.deletingLastPathComponent().path == root.standardizedFileURL.resolvingSymlinksInPath().path,
              !target.lastPathComponent.hasPrefix(".") else {
            throw CocoaError(.fileWriteNoPermission)
        }
        try FileManager.default.removeItem(at: target)
    }

    /// Folders whose notes were never finished: the app quit or crashed with
    /// a call still being written down. Their transcripts are complete up to
    /// that moment and deserve a summary rather than being left half done.
    public func unfinishedFolders() -> [URL] {
        let manager = FileManager.default
        let folders = (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles])) ?? []
        return folders.filter { folder in
            guard let record = loadRecord(in: folder) else { return false }
            let hasNotes = manager.fileExists(atPath: folder.appendingPathComponent(MeetingFiles.notesName).path)
            return record.endedAt == nil || !hasNotes
        }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func write(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
