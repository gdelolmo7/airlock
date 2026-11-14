import AirlockCore
import AppKit
import SwiftUI
import WidgetKit

/// The "Shelf" widget's three sizes, drawn from a snapshot, a look and a way
/// to find each file's picture, so the screenshots can draw every state.
struct ShelfView: View {
    enum Size { case small, medium, large }

    var shelf: DeskShelfFiles
    var size: Size
    var look: DeskLook
    /// The picture for a file, or nil for the plain glyph.
    var picture: (DeskShelfFiles.File) -> NSImage?
    /// False only for the screenshots: an image cannot draw a link.
    var live = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !shelf.isOn {
                note(DeskShelfWords.offTitle, DeskShelfWords.offLine, symbol: "tray")
            } else if shelf.files.isEmpty {
                note(DeskShelfWords.emptyTitle, DeskShelfWords.emptyLine, symbol: "tray")
            } else {
                switch size {
                case .small: small
                case .medium: medium
                case .large: large
                }
            }
        }
        .foregroundStyle(look.fg)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: Sizes

    /// Four pictures, no names; a fifth file and on is a "+N" on the last.
    private var small: some View {
        let shown = Array(shelf.files.prefix(4))
        let extra = shelf.count - shown.count
        return Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        let index = row * 2 + column
                        if index < shown.count {
                            let isLast = index == shown.count - 1 && extra > 0
                            tile(shown[index], more: isLast ? extra + 1 : 0)
                        } else {
                            Color.clear
                        }
                    }
                }
            }
        }
        .padding(.top, 10)
    }

    private var medium: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(0..<4, id: \.self) { index in
                if index < shelf.files.count {
                    named(shelf.files[index])
                } else {
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.top, 10)
    }

    private var large: some View {
        VStack(alignment: .leading, spacing: 16) {
            ForEach(0..<2, id: \.self) { row in
                HStack(alignment: .top, spacing: 10) {
                    ForEach(0..<4, id: \.self) { column in
                        let index = row * 4 + column
                        if index < shelf.files.count {
                            named(shelf.files[index])
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            Text(ByteCountFormatter.string(fromByteCount: shelf.totalSize, countStyle: .file))
                .font(DeskType.mono(11))
                .foregroundStyle(look.fg3)
        }
        .padding(.top, 12)
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(look.accent)
                .widgetAccentable()
            Text(DeskShelfWords.title).font(DeskType.title(14)).lineLimit(1)
            Spacer(minLength: 4)
            if shelf.isOn, shelf.count > 0 {
                Text(DeskShelfWords.files(shelf.count))
                    .font(DeskType.text(11.5, weight: .medium))
                    .foregroundStyle(look.fg2)
                    .lineLimit(1)
            }
        }
    }

    private func note(_ title: String, _ line: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Spacer(minLength: 0)
            Text(title).font(DeskType.title(size == .small ? 15 : 17))
            Text(line)
                .font(DeskType.text(12, weight: .regular))
                .foregroundStyle(look.fg2)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
    }

    /// A picture with its name and what it is under it: the name without
    /// its extension, since the line under it says what kind it is.
    private func named(_ file: DeskShelfFiles.File) -> some View {
        linked(file.openURL) {
            VStack(alignment: .leading, spacing: 5) {
                picture(of: file).aspectRatio(1, contentMode: .fit)
                VStack(alignment: .leading, spacing: 1) {
                    Text(file.title)
                        .font(DeskType.text(11, weight: .medium))
                        .lineLimit(1)
                    Text(file.kind + " · " + ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file))
                        .font(DeskType.mono(9.5))
                        .foregroundStyle(look.fg3)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A picture, or for the last of four when more are on the Shelf, how
    /// many more: a click there opens the Shelf itself.
    @ViewBuilder private func tile(_ file: DeskShelfFiles.File, more: Int) -> some View {
        if more > 0 {
            VStack(spacing: 0) {
                Text("+\(more)").font(DeskType.mono(17, weight: .medium))
                Text(DeskShelfWords.moreWord).font(DeskType.text(10.5, weight: .medium)).foregroundStyle(look.fg2)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(look.well, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        } else {
            linked(file.openURL) { picture(of: file) }
        }
    }

    @ViewBuilder private func picture(of file: DeskShelfFiles.File) -> some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ZStack {
            shape.fill(look.well)
            if let image = picture(file) {
                if file.thumbIsIcon {
                    Image(nsImage: image).resizable().scaledToFit().padding(6)
                } else {
                    Color.clear.overlay {
                        Image(nsImage: image).resizable().scaledToFill()
                    }
                    .clipShape(shape)
                }
            } else {
                VStack(spacing: 3) {
                    Image(systemName: Self.symbol(for: file))
                        .font(.system(size: 18, weight: .regular))
                        .foregroundStyle(look.fg2)
                    Text(file.kind).font(DeskType.mono(8.5, weight: .medium)).foregroundStyle(look.fg3)
                        .lineLimit(1)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    static func symbol(for file: DeskShelfFiles.File) -> String {
        if file.isFolder { return "folder.fill" }
        switch (file.name as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "heic", "gif", "webp", "tiff": return "photo"
        case "mov", "mp4", "m4v": return "film"
        case "mp3", "m4a", "wav", "aiff": return "waveform"
        case "zip": return "doc.zipper"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }

    @ViewBuilder private func linked(_ url: URL?, @ViewBuilder _ label: () -> some View) -> some View {
        if live, let url { Link(destination: url, label: label) } else { label() }
    }
}
