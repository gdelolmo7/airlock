import AirlockCore
import Foundation
import os

/// Does what a chip in the drop box says, off the main actor, and says how it
/// went (`DropWorkResult`). Each kind of file has its own worker
/// (`DropPictureWork`, `DropPDFWork`, `DropMediaWork`, `DropDocumentWork`,
/// `DropBundleWork`); this picks the one for each item and writes what it
/// makes.
///
/// The same promises as `PictureConverter`, for every kind: what was dragged
/// is read and nothing else, and a result is written whole somewhere private
/// and then moved onto a name nothing holds, so the shelf never shows half a
/// film and nothing on it is ever replaced.
enum DropWork {
    /// Why one item gave nothing, said through `DropWorkResult`'s sentences.
    enum Failure: Error {
        case unreadable, unwritable, noWords, noSpeech, noSubject, noSound, alreadySmall
    }

    private static let log = Logger(subsystem: "com.airlock.app", category: "shelf")

    /// `names` are `DropNames`', one per file or folder the choice writes.
    static func run(_ inputs: [PictureInput], choice: DropChoice, names: [String],
                    tray: URL) async -> DropWorkResult {
        switch choice {
        case .picture(let format):
            return await BlockingWork.run {
                let result = PictureConverter.run(inputs, target: .format(format), names: names, tray: tray)
                return DropWorkResult(choice: choice, made: result.made, failures: result.failures)
            }
        case .onePDF:
            guard let name = names.first else { return DropWorkResult(choice: choice, made: 0, failures: []) }
            return await one(choice, name: name, tray: tray) { destination in
                try await BlockingWork.run { Result { try DropPDFWork.join(inputs, at: destination) } }.get()
            }
        case .zip:
            guard let name = names.first else { return DropWorkResult(choice: choice, made: 0, failures: []) }
            return await one(choice, name: name, tray: tray) { destination in
                try await BlockingWork.run { Result { try DropBundleWork.zip(inputs, at: destination) } }.get()
            }
        case .copyText:
            return await copyText(inputs)
        case .writeItOut:
            return await writeOut(inputs)
        default:
            return await each(inputs, choice: choice, names: names, tray: tray)
        }
    }

    /// One result made from every item: one PDF, one zip.
    private static func one(_ choice: DropChoice, name: String, tray: URL,
                            _ body: (URL) async throws -> Void) async -> DropWorkResult {
        do {
            try await write(to: tray.appendingPathComponent(name), body)
            return DropWorkResult(choice: choice, made: 1, failures: [])
        } catch {
            return DropWorkResult(choice: choice, made: 0, failures: [.init(name: name, reason: reason(error))])
        }
    }

    /// One result per item, each written on its own: a film that can't be
    /// read leaves the other two made.
    private static func each(_ inputs: [PictureInput], choice: DropChoice, names: [String],
                             tray: URL) async -> DropWorkResult {
        var made = 0
        var failures: [TrayIngestResult.Failure] = []
        for (input, name) in zip(inputs, names) {
            do {
                try await write(to: tray.appendingPathComponent(name)) { destination in
                    try await make(choice, from: input, at: destination)
                }
                made += 1
            } catch {
                log.error("drop box: \(String(describing: choice), privacy: .public) gave nothing: \(String(describing: error), privacy: .public)")
                failures.append(.init(name: input.name, reason: reason(error)))
            }
        }
        return DropWorkResult(choice: choice, made: made, failures: failures)
    }

    /// What one item becomes, by what it is.
    private static func make(_ choice: DropChoice, from input: PictureInput, at destination: URL) async throws {
        let kind = kind(of: input)
        switch (choice, kind) {
        case (.smaller, .picture):
            try await blocking { try DropPictureWork.smaller(input, at: destination) }
        case (.cutOut, .picture):
            try await blocking { try DropPictureWork.cutOut(input, at: destination) }
        case (.noLocation, .picture):
            try await blocking { try DropPictureWork.withoutLocation(input, at: destination) }
        case (.pages(let format), .pdf):
            try await blocking { try DropPDFWork.pages(of: url(input), as: format, into: destination) }
        case (.splitPages, .pdf):
            try await blocking { try DropPDFWork.split(url(input), into: destination) }
        case (.smaller, .pdf):
            try await blocking { try DropPDFWork.smaller(url(input), at: destination) }
        case (.textFile, .pdf):
            try await blocking { try plainText(DropPDFWork.text(of: url(input)), at: destination) }
        case (.textFile, .document):
            try await blocking { try plainText(DropDocumentWork.text(of: url(input)), at: destination) }
        case (.documentPDF, .document):
            try await blocking { try DropDocumentWork.pdf(of: url(input), at: destination) }
        case (.rtf, .document):
            try await blocking { try DropDocumentWork.rtf(of: url(input), at: destination) }
        case (.mp4, .video):
            try await DropMediaWork.mp4(url(input), at: destination)
        case (.smaller, .video):
            try await DropMediaWork.smaller(url(input), at: destination)
        case (.noSound, .video):
            try await DropMediaWork.withoutSound(url(input), at: destination)
        case (.gif, .video):
            try await DropMediaWork.gif(of: url(input), at: destination)
        case (.soundOnly, .video), (.audio(.m4a), .audio):
            try await DropMediaWork.m4a(url(input), at: destination)
        case (.audio(let format), .audio):
            try await DropMediaWork.pcm(url(input), as: format, at: destination)
        case (.nameInOrder, _):
            try FileManager.default.copyItem(at: url(input), to: destination)
        default:
            // The offer never puts a chip under a kind it can't serve; a
            // drag that changed between the box opening and the drop can.
            throw Failure.unreadable
        }
    }

    /// The words in everything dragged, for the clipboard, in drag order and
    /// a blank line apart.
    private static func copyText(_ inputs: [PictureInput]) async -> DropWorkResult {
        var parts: [String] = []
        var failures: [TrayIngestResult.Failure] = []
        for input in inputs {
            do {
                let words: String = try await BlockingWork.run {
                    Result { () throws -> String in
                        switch kind(of: input) {
                        case .picture: return try DropPictureWork.text(in: input)
                        case .pdf: return try DropPDFWork.text(of: url(input))
                        case .document: return try DropDocumentWork.text(of: url(input))
                        default: throw Failure.unreadable
                        }
                    }
                }.get()
                let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            } catch {
                failures.append(.init(name: input.name, reason: reason(error)))
            }
        }
        if parts.isEmpty, failures.isEmpty, let first = inputs.first {
            failures.append(.init(name: first.name, reason: DropWorkResult.noWords))
        }
        return DropWorkResult(choice: .copyText, made: 0, failures: failures,
                              text: parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
    }

    /// What is said in every recording dragged, for the clipboard, in drag
    /// order and a blank line apart. One that can't be heard leaves the
    /// others' words.
    private static func writeOut(_ inputs: [PictureInput]) async -> DropWorkResult {
        var parts: [String] = []
        var failures: [TrayIngestResult.Failure] = []
        for input in inputs {
            do {
                guard case .audio = kind(of: input) else { throw Failure.unreadable }
                let words = try await DropMediaWork.writtenOut(url(input))
                let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { parts.append(trimmed) }
            } catch {
                log.error("drop box: write it out gave nothing: \(String(describing: error), privacy: .public)")
                failures.append(.init(name: input.name, reason: reason(error)))
            }
        }
        if parts.isEmpty, failures.isEmpty, let first = inputs.first {
            failures.append(.init(name: first.name, reason: DropWorkResult.noSpeech))
        }
        return DropWorkResult(choice: .writeItOut, made: 0, failures: failures,
                              text: parts.isEmpty ? nil : parts.joined(separator: "\n\n"))
    }

    // MARK: - Shared

    static func kind(of input: PictureInput) -> DropSource {
        switch input {
        case .file(let url): return DropReader.source(of: url)
        case .data: return .picture(nil)
        }
    }

    /// Everything but a picture off a web page is a file.
    static func url(_ input: PictureInput) throws -> URL {
        guard case .file(let url) = input else { throw Failure.unreadable }
        return url
    }

    static func plainText(_ words: String, at destination: URL) throws {
        let trimmed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw Failure.noWords }
        try Data((trimmed + "\n").utf8).write(to: destination)
    }

    private static func blocking(_ body: @escaping @Sendable () throws -> Void) async throws {
        try await BlockingWork.run { Result { try body() } }.get()
    }

    /// `PictureConverter.write`, for work that waits on AVFoundation: written
    /// whole beside the shelf, then moved onto a name nothing holds.
    private static func write(to destination: URL, _ body: (URL) async throws -> Void) async throws {
        let manager = FileManager.default
        let scratch = try manager.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                      appropriateFor: destination, create: true)
        defer { try? manager.removeItem(at: scratch) }
        let temporary = scratch.appendingPathComponent(destination.lastPathComponent)
        try await body(temporary)
        try manager.moveItem(at: temporary, to: destination)
    }

    private static func reason(_ error: any Error) -> String {
        switch error {
        case let failure as Failure:
            switch failure {
            case .unreadable: return DropWorkResult.unreadable
            case .unwritable: return DropWorkResult.unwritable
            case .noWords: return DropWorkResult.noWords
            case .noSpeech: return DropWorkResult.noSpeech
            case .noSubject: return DropWorkResult.noSubject
            case .noSound: return DropWorkResult.noSound
            case .alreadySmall: return DropWorkResult.alreadySmall
            }
        case let failure as PictureConverter.Failure:
            return failure == .unreadable ? DropWorkResult.unreadable : DropWorkResult.unwritable
        default:
            log.error("drop box: \(error.localizedDescription, privacy: .private)")
            return PlainProblem.file(error)
        }
    }
}
