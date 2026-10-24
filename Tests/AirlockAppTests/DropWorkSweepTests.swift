import AppKit
import AVFoundation
import XCTest
import AirlockCore
@testable import AirlockApp

/// Every chip the drop box offers, run for real on a real file of each kind:
/// a picture with words, a two-page PDF, Word, RTF and plain text, a film
/// with sound, a sound file, and several at once. A chip that gives nothing
/// would show up here as a failure with its reason, where a unit test of the
/// offer alone would pass.
///
/// Slow (films, speech), so it runs only with `AIRLOCK_DROP_SWEEP=1`.
@MainActor
final class DropWorkSweepTests: XCTestCase {
    private var root: URL!

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["AIRLOCK_DROP_SWEEP"] == "1" else {
            throw XCTSkip("set AIRLOCK_DROP_SWEEP=1 to run every drop box chip")
        }
        root = FileManager.default.temporaryDirectory.appendingPathComponent("drop-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testEveryChipOnEveryKindMakesSomething() async throws {
        let samples = try await makeSamples()
        var report: [String] = []
        var broken: [String] = []
        for (label, files) in samples {
            let offer = DropOffer.make(sources: files.map(DropReader.source(of:)),
                                       abilities: DropReader.abilities(takesNotes: true))
            XCTAssertFalse(offer.formats.isEmpty && offer.actions.isEmpty, "\(label) gets no chips")
            // Smaller has its own test, on files big enough to shrink.
            for choice in offer.formats + offer.actions where choice != .notesFromIt && choice != .smaller {
                let tray = root.appendingPathComponent("tray-\(UUID().uuidString)")
                try FileManager.default.createDirectory(at: tray, withIntermediateDirectories: true)
                let inputs = files.map(PictureInput.file)
                // Named as `TrayModel.perform` names them.
                let keeps: Set<String>?, fallback: String
                switch DropWork.kind(of: inputs[0]) {
                case .picture: (keeps, fallback) = (DropReader.keptPictureExtensions, "jpg")
                case .video: (keeps, fallback) = (DropReader.keptVideoExtensions, "mp4")
                default: (keeps, fallback) = (nil, "")
                }
                let names = DropNames.names(for: inputs.map(\.name), choice: choice, existing: [],
                                            keeps: keeps, fallback: fallback)
                let started = Date()
                let result = await DropWork.run(inputs, choice: choice,
                                                names: names, tray: tray)
                let seconds = Date().timeIntervalSince(started)
                let onShelf = (try? FileManager.default.contentsOfDirectory(atPath: tray.path)) ?? []
                let ok = result.failures.isEmpty && (result.text != nil || !onShelf.isEmpty)
                let line = "\(ok ? "ok  " : "FAIL") \(label) → \(choice.label(count: files.count))"
                    + String(format: " (%.1fs)", seconds)
                    + (result.text != nil ? " copied \(result.text!.count) chars" : " made \(onShelf.joined(separator: ", "))")
                    + (result.failures.isEmpty ? "" : " — " + result.failures.map(\.reason).joined(separator: "; "))
                report.append(line)
                if !ok { broken.append(line) }
            }
        }
        print("DROP SWEEP\n" + report.joined(separator: "\n"))
        XCTAssertTrue(broken.isEmpty, broken.joined(separator: "\n"))
    }

    /// "Smaller" refuses whatever wouldn't come out smaller, so the small
    /// samples above can't show it working. These are big: a wallpaper as a
    /// PNG, the same picture in a PDF, and a wallpaper film.
    func testSmallerShrinksBigFiles() async throws {
        let wallpaper = URL(fileURLWithPath: "/System/Library/Desktop Pictures/Mac Blue.heic")
        let film = URL(fileURLWithPath: "/System/Library/Desktop Pictures/.wallpapers/Sonoma/Sonoma Graphic Dark Portrait.mov")
        guard FileManager.default.fileExists(atPath: wallpaper.path),
              FileManager.default.fileExists(atPath: film.path) else {
            throw XCTSkip("this macOS has no wallpapers to try Smaller on")
        }
        let png = root.appendingPathComponent("big.png")
        let pdf = root.appendingPathComponent("big.pdf")
        let image = try XCTUnwrap(NSImage(contentsOf: wallpaper))
        let rep = try XCTUnwrap(image.representations.first)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: png)
        var box = CGRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh)
        let context = try XCTUnwrap(CGContext(pdf as CFURL, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.draw(try XCTUnwrap(bitmap.cgImage), in: box)
        context.endPDFPage()
        context.closePDF()
        let movie = try copy(film, as: "big.mov")

        var broken: [String] = []
        for file in [png, pdf, movie] {
            let tray = root.appendingPathComponent("tray-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: tray, withIntermediateDirectories: true)
            let input = PictureInput.file(file)
            let keeps: Set<String>?, fallback: String
            switch DropWork.kind(of: input) {
            case .picture: (keeps, fallback) = (DropReader.keptPictureExtensions, "jpg")
            case .video: (keeps, fallback) = (DropReader.keptVideoExtensions, "mp4")
            default: (keeps, fallback) = (nil, "")
            }
            let names = DropNames.names(for: [input.name], choice: .smaller, existing: [],
                                        keeps: keeps, fallback: fallback)
            let started = Date()
            let result = await DropWork.run([input], choice: .smaller, names: names, tray: tray)
            let made = names.first.map { tray.appendingPathComponent($0) }
            let before = DropPictureWork.fileSize(file) ?? 0
            let after = made.flatMap(DropPictureWork.fileSize) ?? 0
            let line = String(format: "%@ → Smaller (%.1fs): %.1f MB → %.1f MB %@", file.lastPathComponent,
                              Date().timeIntervalSince(started), Double(before) / 1e6, Double(after) / 1e6,
                              result.failures.map(\.reason).joined(separator: "; "))
            print("DROP SMALLER " + line)
            if !result.failures.isEmpty || after == 0 || after >= before { broken.append(line) }
        }
        XCTAssertTrue(broken.isEmpty, broken.joined(separator: "\n"))
    }

    // MARK: - Samples

    private func makeSamples() async throws -> [(String, [URL])] {
        let png = try picture("words.png", type: .png)
        let jpg = try picture("photo.jpg", type: .jpeg)
        let pdf = try twoPagePDF("pages.pdf")
        let text = root.appendingPathComponent("note.txt")
        try "Hello from Airlock. The drop box reads this.".write(to: text, atomically: true, encoding: .utf8)
        let words = NSAttributedString(string: "Hello from Airlock. The drop box reads this document.")
        let rtf = root.appendingPathComponent("letter.rtf")
        try words.rtf(from: NSRange(location: 0, length: words.length), documentAttributes: [:])?.write(to: rtf)
        let docx = root.appendingPathComponent("report.docx")
        try words.data(from: NSRange(location: 0, length: words.length),
                       documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
            .write(to: docx)
        let sound = try await speech("voice.m4a")
        let film = try await filmWithSound("clip.mov", sound: sound)
        return [
            ("picture (PNG)", [png]),
            ("2 pictures", [png, jpg]),
            ("PDF", [pdf]),
            ("2 PDFs", [pdf, try copy(pdf, as: "pages2.pdf")]),
            ("Word", [docx]),
            ("RTF", [rtf]),
            ("text", [text]),
            ("film (MOV)", [film]),
            ("sound (M4A)", [sound]),
            ("mixed", [png, pdf, docx]),
            ("folder", [root.appendingPathComponent("folder-\(UUID().uuidString)", isDirectory: true).also {
                try? FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true)
                try? "inside".write(to: $0.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
            }]),
        ]
    }

    private func copy(_ url: URL, as name: String) throws -> URL {
        let destination = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: url, to: destination)
        return destination
    }

    private func picture(_ name: String, type: NSBitmapImageRep.FileType) throws -> URL {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 300,
                                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 800, height: 300).fill()
        NSColor.systemBlue.setFill()
        NSBezierPath(ovalIn: NSRect(x: 560, y: 60, width: 180, height: 180)).fill()
        ("Hello Airlock" as NSString).draw(at: NSPoint(x: 40, y: 120), withAttributes: [
            .font: NSFont.systemFont(ofSize: 64, weight: .bold), .foregroundColor: NSColor.black,
        ])
        NSGraphicsContext.restoreGraphicsState()
        let url = root.appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: type, properties: [:])).write(to: url)
        return url
    }

    private func twoPagePDF(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &box, nil))
        for page in 1...2 {
            context.beginPDFPage(nil)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Page \(page): hello from Airlock" as NSString).draw(at: NSPoint(x: 72, y: 700), withAttributes: [
                .font: NSFont.systemFont(ofSize: 24),
            ])
            NSGraphicsContext.restoreGraphicsState()
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }

    /// Spoken words, so "Write it out" has something to write.
    private func speech(_ name: String) async throws -> URL {
        let aiff = root.appendingPathComponent("voice.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-o", aiff.path, "Hello from Airlock. This is the drop box writing out what is said."]
        try say.run()
        say.waitUntilExit()
        let url = root.appendingPathComponent(name)
        try await DropMediaWork.m4a(aiff, at: url)
        return url
    }

    /// A few seconds of picture with the sound under it.
    private func filmWithSound(_ name: String, sound: URL) async throws -> URL {
        let url = root.appendingPathComponent(name)
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        let size = CGSize(width: 320, height: 240)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: size.width, AVVideoHeightKey: size.height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: size.width, kCVPixelBufferHeightKey as String: size.height,
        ])
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<90 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, Int(size.width), Int(size.height), kCVPixelFormatType_32BGRA, nil, &buffer)
            let pixels = try XCTUnwrap(buffer)
            CVPixelBufferLockBaseAddress(pixels, [])
            memset(CVPixelBufferGetBaseAddress(pixels), Int32(frame * 2 % 255), CVPixelBufferGetDataSize(pixels))
            CVPixelBufferUnlockBaseAddress(pixels, [])
            adaptor.append(pixels, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30))
        }
        input.markAsFinished()
        await writer.finishWriting()
        let silent = url

        // Put the sound under the picture.
        let composition = AVMutableComposition()
        let picture = AVURLAsset(url: silent)
        let voice = AVURLAsset(url: sound)
        let length = try await picture.load(.duration)
        let videoTrack = try await XCTUnwrapAsync(try await picture.loadTracks(withMediaType: .video).first)
        let audioTrack = try await XCTUnwrapAsync(try await voice.loadTracks(withMediaType: .audio).first)
        try composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: length), of: videoTrack, at: .zero)
        try composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)?
            .insertTimeRange(CMTimeRange(start: .zero, duration: length), of: audioTrack, at: .zero)
        let withSound = root.appendingPathComponent("with-sound-" + name)
        let export = try XCTUnwrap(AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough))
        try await export.export(to: withSound, as: .mov)
        try FileManager.default.removeItem(at: silent)
        try FileManager.default.moveItem(at: withSound, to: url)
        return url
    }

    private func XCTUnwrapAsync<T>(_ value: T?) async throws -> T { try XCTUnwrap(value) }
}

private extension URL {
    func also(_ body: (URL) -> Void) -> URL { body(self); return self }
}
