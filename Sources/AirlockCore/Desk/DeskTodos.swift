import Foundation

/// The to-dos from today's calls, as the desktop widget shows them.
///
/// The app reads every call's notes page and writes this snapshot where the
/// widget can read it (`DeskShelf`); the widget never opens a notes page
/// itself. A tick in the widget comes back as a `DeskTick`, which the app
/// writes into the page as "- [x]", so the page stays the one place a to-do
/// is kept and a tick made in a text editor shows on the desk too.
public struct DeskTodos: Codable, Equatable, Sendable {
    public struct Item: Codable, Equatable, Sendable, Identifiable {
        /// The call's folder name and the to-do's place on its page: stable
        /// while the page is not rewritten, and all a tick needs.
        public var id: String { "\(folder)#\(index)" }
        public var text: String
        /// The call's name, as the notes window lists it ("Design review").
        public var call: String
        /// When the call started.
        public var at: Date
        public var done: Bool
        /// The call's folder, by name, under the meetings folder.
        public var folder: String
        /// Which box on the page this is, counting from 0, in page order.
        public var index: Int

        public init(text: String, call: String, at: Date, done: Bool, folder: String, index: Int) {
            self.text = text
            self.call = call
            self.at = at
            self.done = done
            self.folder = folder
            self.index = index
        }
    }

    /// The day these are from, at its first moment.
    public var day: Date
    /// In call order, then page order.
    public var items: [Item]
    /// How many of today's calls left at least one to-do.
    public var calls: Int
    /// What the widget is drawn on: the notch's own choice, so the two look
    /// the same. Nil (a snapshot from before it was carried) is black.
    public var surface: DeskSurface?

    public init(day: Date, items: [Item], calls: Int, surface: DeskSurface? = nil) {
        self.day = day
        self.items = items
        self.calls = calls
        self.surface = surface
    }

    public static func empty(on day: Date) -> DeskTodos { DeskTodos(day: day, items: [], calls: 0) }

    public var left: Int { items.count(where: { !$0.done }) }
    public var ticked: Int { items.count(where: { $0.done }) }
    /// Every to-do of the day ticked, and there was at least one: the cloud.
    public var allDone: Bool { !items.isEmpty && left == 0 }

    /// Open ones first, then ticked, each in their own order: what the small
    /// and medium sizes show, so the top of the list is what is left.
    public var openFirst: [Item] { items.filter { !$0.done } + items.filter(\.done) }

    /// The same snapshot with one to-do ticked or unticked, as the widget
    /// draws it straight after a press, before the app has caught up.
    public func setting(_ id: String, done: Bool) -> DeskTodos {
        var copy = self
        for i in copy.items.indices where copy.items[i].id == id { copy.items[i].done = done }
        return copy
    }

    /// What the widget shows on a day that is over: a snapshot from an
    /// earlier day is nothing to do today.
    public func on(_ now: Date, calendar: Calendar = .current) -> DeskTodos {
        calendar.isDate(day, inSameDayAs: now) ? self : .empty(on: calendar.startOfDay(for: now))
    }

    // MARK: - Built from the calls

    /// One call as the snapshot needs it: where it is, its record, its page.
    public struct Call: Sendable {
        public var folder: String
        public var record: MeetingRecord
        public var page: String?

        public init(folder: String, record: MeetingRecord, page: String?) {
            self.folder = folder
            self.record = record
            self.page = page
        }
    }

    /// The to-dos of the calls that started today, earliest call first.
    public static func today(_ calls: [Call], now: Date, calendar: Calendar = .current) -> DeskTodos {
        let todays = calls
            .filter { calendar.isDate($0.record.startedAt, inSameDayAs: now) }
            .sorted { $0.record.startedAt < $1.record.startedAt }
        var items: [Item] = []
        var withTodos = 0
        for call in todays {
            guard let page = call.page else { continue }
            let boxes = Self.boxes(in: page)
            if !boxes.isEmpty { withTodos += 1 }
            let name = MeetingFiles.title(of: call.record)
            for (index, box) in boxes.enumerated() {
                items.append(Item(text: box.text, call: name, at: call.record.startedAt,
                                  done: box.done, folder: call.folder, index: index))
            }
        }
        return DeskTodos(day: calendar.startOfDay(for: now), items: items, calls: withTodos)
    }

    /// Every "- [ ]" and "- [x]" on a page, in order, as the notes window
    /// reads them (`MeetingPage`): the owner and the time are left off.
    public static func boxes(in page: String) -> [(text: String, done: Bool)] {
        MeetingPage.blocks(of: page).compactMap {
            if case .item(let text, let checked?, _, _) = $0 { (text, checked) } else { nil }
        }
    }

    /// The page with box `index` ticked (or unticked), and nothing else
    /// changed: not a space, not the line's owner or time. Nil when there is
    /// no such box, or when `text` is given and the box no longer says it,
    /// because the page was rewritten since the widget was drawn: a tick
    /// never lands on a different to-do.
    public static func ticking(_ page: String, index: Int, text: String?, done: Bool) -> String? {
        var lines = page.components(separatedBy: "\n")
        var seen = 0
        for i in lines.indices {
            guard let box = boxRange(in: lines[i]) else { continue }
            defer { seen += 1 }
            guard seen == index else { continue }
            if let text, boxes(in: lines[i]).first?.text != text { return nil }
            lines[i].replaceSubrange(box, with: done ? "[x]" : "[ ]")
            return lines.joined(separator: "\n")
        }
        return nil
    }

    /// Where "[ ]" or "[x]" sits on a to-do line, the same lines
    /// `MeetingPage` reads as boxes: a "-", "*" or "•", a space, the box and
    /// a space.
    private static func boxRange(in line: String) -> Range<String.Index>? {
        let body = line.drop { $0 == " " || $0 == "\t" }
        guard let marker = body.first, "-*•".contains(marker),
              body.dropFirst().first == " " else { return nil }
        let start = body.index(body.startIndex, offsetBy: 2)
        let rest = body[start...]
        guard ["[ ] ", "[x] ", "[X] "].contains(where: { rest.hasPrefix($0) }) else { return nil }
        return start..<body.index(start, offsetBy: 3)
    }
}

/// The notch's ground (Settings › Appearance), told to the widget so a
/// desktop widget and the island are drawn on the same thing. The raw
/// values are the notch setting's own, so one maps onto the other by name.
public enum DeskSurface: String, Codable, Sendable, CaseIterable {
    case black
    case darkGlass
    case lightGlass

    /// Light text on it, or dark: only light glass is light.
    public var isDark: Bool { self != .lightGlass }
    public var isGlass: Bool { self != .black }
}

/// A press on a to-do in the widget, left for the app in the shared folder.
///
/// The widget may not write into `~/Airlock/Meetings` (it runs in a sandbox
/// that cannot see it), so it drops one of these and the app, which watches
/// the folder, writes the tick into the page.
public struct DeskTick: Codable, Equatable, Sendable {
    public var folder: String
    public var index: Int
    public var text: String
    public var done: Bool
    public var at: Date

    public init(folder: String, index: Int, text: String, done: Bool, at: Date) {
        self.folder = folder
        self.index = index
        self.text = text
        self.done = done
        self.at = at
    }

    public init(_ item: DeskTodos.Item, done: Bool, at: Date) {
        self.init(folder: item.folder, index: item.index, text: item.text, done: done, at: at)
    }

    /// The folder name is the one thing in a tick that names a place on
    /// disk, and it comes from a file anybody could write: only a plain name
    /// is honoured, never a path.
    public var isPlainFolder: Bool {
        !folder.isEmpty && !folder.contains("/") && folder != "." && folder != ".."
            && !folder.hasPrefix(".") && index >= 0
    }
}

/// Where the app and the widget meet: the App Group's folder, which both
/// can read and write. The widget is sandboxed and sees nothing else.
public enum DeskShelf {
    /// The Info.plist key packaging puts the group in, in both the app and
    /// the widget. Missing means this build has no widget (a dev build,
    /// `swift run`), and the app publishes nothing.
    public static let infoKey = "ALAppGroup"
    public static let snapshotName = "desk-todos.json"
    public static let ticksFolder = "ticks"
    /// The link a click on the widget opens: the calls window, newest call.
    public static let openURL = URL(string: "airlock://call-todos")!

    /// The group a team signs for: "TEAMID.com.airlock.app". A group must
    /// start with the team on macOS, or the system asks the person whether
    /// Airlock may read another app's data.
    public static func group(team: String) -> String { "\(team).com.airlock.app" }

    public static func isOpenURL(_ url: URL) -> Bool {
        url.scheme == openURL.scheme && url.host == openURL.host
    }

    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// A tick's file name: when it was made, so the app applies them in the
    /// order they were pressed, and a random tail so two never collide.
    public static func tickName(_ tick: DeskTick) -> String {
        "\(Int(tick.at.timeIntervalSince1970 * 1000))-\(UUID().uuidString.prefix(8)).json"
    }
}

/// The widget's words, kept here so they are tested and translated with the
/// rest of the app's.
public enum DeskWords {
    public static let name = String(localized: "Call to-dos")
    public static let blurb = String(localized: "The to-dos from today's calls. Tick them off here.")
    public static let small = String(localized: "To-dos")
    public static let medium = String(localized: "To-dos from today's calls")
    public static let large = String(localized: "From today's calls")
    public static let allDone = String(localized: "All done")
    public static let leftFromToday = String(localized: "left from today's calls")
    public static let nothingTitle = String(localized: "No to-dos yet")
    public static let nothingLine = String(localized: "To-dos from today's calls will show here.")
    public static let tick = String(localized: "Tick")
    public static let untick = String(localized: "Untick")

    public static func left(_ n: Int) -> String { String(localized: "\(n) left") }

    public static func doneOf(_ done: Int, _ all: Int) -> String {
        String(localized: "\(done) of \(all) done")
    }

    public static func tickedToday(_ done: Int, _ all: Int) -> String {
        String(localized: "\(done) of \(all) ticked today")
    }

    /// "5 things from 3 calls, all ticked." Under the cloud, medium.
    public static func allTicked(_ things: Int, calls: Int) -> String {
        switch (things == 1, calls == 1) {
        case (true, _): String(localized: "1 thing from 1 call, ticked.")
        case (false, true): String(localized: "\(things) things from 1 call, all ticked.")
        case (false, false): String(localized: "\(things) things from \(calls) calls, all ticked.")
        }
    }

    /// "5 things from 3 calls". Beside the cloud, large.
    public static func things(_ things: Int, calls: Int) -> String {
        switch (things == 1, calls == 1) {
        case (true, _): String(localized: "1 thing from 1 call")
        case (false, true): String(localized: "\(things) things from 1 call")
        case (false, false): String(localized: "\(things) things from \(calls) calls")
        }
    }
}
