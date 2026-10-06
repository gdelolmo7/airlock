import AppKit
import EventKit
import Observation
import AirlockCore

/// One upcoming event, decoupled from EventKit so views never touch EKEvent.
struct CalendarEvent: Identifiable, Equatable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendarID: String
    let color: NSColor?
    /// The call this event joins, if any — provider included, so the button can
    /// name what it opens instead of saying a generic "Join".
    let meeting: MeetingLink?
    let isAllDay: Bool
}

/// Upcoming-events state. Glance tier: from T-10min before the next event
/// until 5min after it starts, the compact island shows a hint — it never
/// expands on its own, per the contract.
@MainActor
@Observable
final class CalendarWidgetModel {
    private(set) var upcoming: [CalendarEvent] = []
    private(set) var authStatus: EKAuthorizationStatus = .notDetermined
    var accessNote: String?

    /// Day picked in the week strip. `nil` is the default rolling agenda —
    /// picking a day is a detour, and it snaps back rather than becoming a mode
    /// you can get stranded in.
    private(set) var selectedDay: Date?
    private(set) var selectedDayEvents: [CalendarEvent] = []
    /// Start-of-day dates in the strip's range holding at least one event, so
    /// the strip can mark them. Only populated for days we've actually read.
    private(set) var daysWithEvents: Set<Date> = []

    @ObservationIgnored private let toggle = WidgetToggle(key: "widget.calendar.enabled", defaultValue: true)
    /// Stored, not computed over UserDefaults: `@Observable` cannot track a
    /// computed property reading `@ObservationIgnored` storage, so toggling this
    /// in settings wrote the value without invalidating anything that reads it.
    var isEnabled: Bool = WidgetToggle.stored("widget.calendar.enabled", default: true) {
        didSet {
            guard isEnabled != oldValue else { return }
            toggle.value = isEnabled
            if !isEnabled { upcoming = [] }
            onChange?()
            if isEnabled { Task { await refresh() } }
        }
    }

    /// Which calendars the user picked in settings. See `CalendarSelection` for
    /// why it is a tri-state and not a set — an empty set used to mean "all",
    /// so unticking the last calendar switched every one of them back on.
    ///
    /// Stored for the same reason as `isEnabled`: computed over UserDefaults it
    /// was invisible to `@Observable`, so ticking a calendar in settings changed
    /// the stored set without redrawing the row that shows it.
    @ObservationIgnored private static let selectedKey = "widget.calendar.selected"
    var selection = CalendarSelection(
        stored: UserDefaults.standard.stringArray(forKey: CalendarWidgetModel.selectedKey)
    ) {
        didSet {
            guard selection != oldValue, !isPreview else { return }
            UserDefaults.standard.set(selection.stored, forKey: Self.selectedKey)
            Task { await refresh() }
            Task { await refreshStripMarkers() }
        }
    }

    @ObservationIgnored var onChange: (() -> Void)?
    /// Set by the controller: opening a link or Calendar.app leaves the notch.
    @ObservationIgnored var onNavigateAway: (() -> Void)?
    /// Lazy so that only a model that reads or asks ever opens the store — the
    /// gallery's `init(previewing:)` never does.
    @ObservationIgnored private lazy var store = EKEventStore()
    @ObservationIgnored private var observer: NSObjectProtocol?
    @ObservationIgnored private var tickTask: Task<Void, Never>?
    @ObservationIgnored private var lastGlance = false
    /// Set only by `init(previewing:)`.
    @ObservationIgnored private var isPreview = false

    init() {}

    /// For the state gallery only: a model that holds these values and does
    /// nothing else. No store is opened, nothing is fetched, no permission is
    /// read or asked for, and `start()` is never called — so the access card
    /// and the agenda can be drawn in every state without a Calendar dialog
    /// or a single EventKit call.
    init(previewing authStatus: EKAuthorizationStatus, upcoming: [CalendarEvent] = [],
         selectedDay: Date? = nil, dayEvents: [CalendarEvent] = [], daysWithEvents: Set<Date> = [],
         isLoadingDay: Bool = false, outcome: CalendarAccessOutcome? = nil, accessNote: String? = nil,
         selection: CalendarSelection = .unchosen) {
        // First, so the selection below can't reach the preferences or the
        // store: a gallery's pretend choice must never be saved as a real one.
        self.isPreview = true
        self.authStatus = authStatus
        self.selection = selection
        self.upcoming = upcoming
        self.selectedDay = selectedDay
        self.selectedDayEvents = dayEvents
        self.daysWithEvents = daysWithEvents
        self.isLoadingDay = isLoadingDay
        self.lastOutcome = outcome
        self.accessNote = accessNote
    }

    /// The glance window around the next event.
    var glanceEvent: CalendarEvent? {
        let now = Date()
        return upcoming.first { event in
            !event.isAllDay
                && event.start.timeIntervalSince(now) < 10 * 60
                && now.timeIntervalSince(event.start) < 5 * 60
        }
    }

    func start() {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        observer = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refresh()
                await self?.refreshStripMarkers()
                await self?.loadSelectedDay()
            }
        }
        // A minute-tick re-derives "upcoming" and the glance window; glance
        // transitions must reach the controller even with zero calendar edits.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self else { return }
                await self.refresh()
            }
        }
        Task { await refresh() }
        Task { await refreshStripMarkers() }
    }

    // MARK: - Week strip

    /// Range the strip covers, and therefore the only span we claim to know
    /// about. Bounded on purpose: an unbounded fetch on every calendar change
    /// would be a lot of work for a widget nobody is looking at.
    static let stripPastDays = 7
    static let stripFutureDays = 45

    /// True between picking a day and its events arriving. The view shows a
    /// skeleton for that window — clearing the list first made the whole card
    /// vanish and reappear, which reads as a glitch even though it is only a
    /// few frames.
    private(set) var isLoadingDay = false

    func select(day: Date?) {
        let normalised = day.map { Calendar.current.startOfDay(for: $0) }
        guard normalised != selectedDay else { return }
        selectedDay = normalised
        if normalised == nil {
            selectedDayEvents = []
            isLoadingDay = false
        } else {
            isLoadingDay = true
        }
        onChange?()
        if normalised != nil { Task { await loadSelectedDay() } }
    }

    private func loadSelectedDay() async {
        guard let day = selectedDay, isEnabled, authStatus == .fullAccess else {
            isLoadingDay = false
            onChange?()
            return
        }
        let cal = Calendar.current
        guard let end = cal.date(byAdding: .day, value: 1, to: day) else {
            isLoadingDay = false
            return
        }
        // Timed before all-day, then by start. There is no cap on a picked day,
        // so the partition no longer decides what you see — the card draws
        // all-day events as a chip strip above the timed rows — but it keeps the
        // order deterministic, and each list stays sorted by start once split.
        let events = fetch(from: day, to: end)
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return a.startDate < b.startDate
            }
            .map(map(_:))
        guard selectedDay == day else { return } // a newer pick won
        selectedDayEvents = events
        isLoadingDay = false
        onChange?()
    }

    /// Which days in range have anything on them. Without this the strip would
    /// have to either show no marks or invent them.
    private func refreshStripMarkers() async {
        guard isEnabled, authStatus == .fullAccess else {
            if !daysWithEvents.isEmpty { daysWithEvents = []; onChange?() }
            return
        }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        guard let start = cal.date(byAdding: .day, value: -Self.stripPastDays, to: today),
              let end = cal.date(byAdding: .day, value: Self.stripFutureDays, to: today) else { return }

        var marked: Set<Date> = []
        for event in fetch(from: start, to: end) {
            var cursor = cal.startOfDay(for: event.startDate)
            let last = cal.startOfDay(for: event.endDate)
            // A multi-day event marks every day it touches.
            while cursor <= last, cursor < end {
                marked.insert(cursor)
                guard let next = cal.date(byAdding: .day, value: 1, to: cursor) else { break }
                cursor = next
            }
        }
        guard marked != daysWithEvents else { return }
        daysWithEvents = marked
        onChange?()
    }

    private func fetch(from start: Date, to end: Date) -> [EKEvent] {
        // nil is "every calendar" to `predicateForEvents`, which is right for a
        // selection nobody has made and exactly wrong for an empty one — so an
        // empty list of matches is a fetch we must not make rather than one to
        // widen. That also covers a pick whose calendars have since been
        // deleted, which would otherwise silently mean "all of them".
        guard selection.chosen != nil else {
            return store.events(matching: store.predicateForEvents(
                withStart: start, end: end, calendars: nil))
        }
        let calendars = store.calendars(for: .event)
            .filter { selection.includes($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: calendars
        )
        return store.events(matching: predicate)
    }

    private func map(_ event: EKEvent) -> CalendarEvent {
        CalendarEvent(
            id: event.eventIdentifier ?? UUID().uuidString,
            title: event.title ?? "Untitled",
            start: event.startDate,
            end: event.endDate,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            color: event.calendar?.color,
            meeting: MeetingLinks.detect(
                url: event.url?.absoluteString,
                location: event.location,
                notes: event.notes
            ),
            isAllDay: event.isAllDay
        )
    }

    /// What the last request turned out to be, so the UI can offer the remedy
    /// that matches it rather than the one that matches the status.
    private(set) var lastOutcome: CalendarAccessOutcome?

    /// What the card says instead of the agenda, or nil when the agenda can
    /// show. Status and outcome together: see `CalendarAccessCard`.
    var accessCard: CalendarAccessCard? {
        CalendarAccessCard.card(status: CalendarAuthorization(authStatus), outcome: lastOutcome)
    }

    /// The card's one button.
    func performRemedy(_ remedy: CalendarAccessCard.Remedy) {
        switch remedy {
        case .ask, .tryAgain: Task { await requestAccess() }
        case .openSystemSettings: openPrivacySettings()
        case .nothing: break
        }
    }

    /// The header's right-hand side: what the list below covers. It said "Next
    /// 24 hours" above a picked day's list too, which is the one thing that
    /// list is not.
    static func scopeLabel(selectedDay: Date?, now: Date = Date(), calendar cal: Calendar = .current) -> String {
        guard let day = selectedDay else { return "Next 24 hours" }
        if cal.isDate(day, inSameDayAs: now) { return "Today" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(day, inSameDayAs: tomorrow) {
            return "Tomorrow"
        }
        if let yesterday = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        return day.formatted(.dateTime.weekday(.wide).day())
    }

    /// Shown in place of "No meetings" when the person has unticked every
    /// calendar: the list is empty because of a choice, not a quiet week.
    static let nothingTicked = "No calendars are ticked, so no meetings can show here."
    static let chooseCalendars = "Choose Calendars"

    /// Ask for full calendar access. Only ever called from an explicit user
    /// action — no TCC prompt ambushes at launch.
    ///
    /// **Awaitable rather than fire-and-forget**, because the Permissions pane
    /// asks for several things in a row and they must not overlap: macOS shows
    /// one TCC dialog at a time, and a request raised while another is on screen
    /// can be answered for the user instead of by them. Callers with nothing to
    /// sequence wrap it in a `Task`.
    /// Re-reads the permission after it changed in System Settings, and
    /// loads the agenda when it has just been allowed. Does nothing when
    /// nothing changed, so a page polling it costs one status read.
    func recheckAuthorization() {
        let now = EKEventStore.authorizationStatus(for: .event)
        guard now != authStatus else { return }
        authStatus = now
        Task {
            await refresh()
            await refreshStripMarkers()
            await loadSelectedDay()
        }
    }

    func requestAccess() async {
        guard AppBundle.isBundled else {
            accessNote = "Calendar access only works in the installed Airlock app."
            return
        }
        do {
            let before = EKEventStore.authorizationStatus(for: .event)
            var thrown: String?
            // Timed, because the duration is the evidence: a refusal that never
            // put a dialog on screen returns in milliseconds, and only the clock
            // tells it apart from someone clicking "Don't Allow".
            let started = Date()
            do {
                _ = try await store.requestFullAccessToEvents()
            } catch {
                thrown = error.localizedDescription
                Log.widgets.error("calendar access request threw: \(error.localizedDescription, privacy: .private)")
            }
            let elapsed = Date().timeIntervalSince(started)
            authStatus = EKEventStore.authorizationStatus(for: .event)
            let outcome = CalendarAccessDiagnosis.outcome(
                before: CalendarAuthorization(before),
                after: CalendarAuthorization(authStatus),
                elapsed: elapsed
            )
            lastOutcome = outcome
            // All public: authorization states, a duration and our own enum —
            // this is the diagnosis CalendarAccessDiagnosis exists to make
            // legible, and it names no user data.
            let after = authStatus.rawValue
            let ms = elapsed * 1000
            Log.widgets.notice("calendar access \(before.rawValue, privacy: .public) → \(after, privacy: .public) in \(ms, format: .fixed(precision: 0), privacy: .public)ms (\(String(describing: outcome), privacy: .public))")

            accessNote = Self.accessNote(for: outcome, thrown: thrown)
            await refresh()
        }
    }

    /// What the card says after a request. Never fail silently: name the
    /// outcome and the way out. Static so the state gallery shows the same
    /// sentences without asking anything.
    static func accessNote(for outcome: CalendarAccessOutcome, thrown: String? = nil) -> String? {
        switch outcome {
        case .granted:
            return nil
        case .promptSuppressed:
            return "macOS didn't show its question. Quit Airlock, open it again from Finder, then try again."
        case .declined:
            return "Calendar access is turned off. Turn it on in System Settings."
        case .standingDenial:
            return "Calendar access is turned off for Airlock. Turn it on in System Settings."
        case .inconclusive:
            // macOS's own words were logged where they were caught.
            return thrown == nil ? nil : "Calendar access couldn't be asked for. Try again in a moment."
        }
    }

    /// Deep-link to the Calendars privacy pane for the denied case.
    func openPrivacySettings() {
        PermissionPage.permission(.calendar).open()
        onNavigateAway?()
    }

    var allCalendars: [(id: String, title: String, color: NSColor?)] {
        guard authStatus == .fullAccess else { return [] }
        return store.calendars(for: .event)
            .map { ($0.calendarIdentifier, $0.title, $0.color) }
            .sorted { $0.1 < $1.1 }
    }

    /// Next 24h, capped at 3, timed events taking every slot before an all-day
    /// one gets any — the cap is where "all-day noise excluded" actually lives,
    /// and on a busy day it excludes them entirely. The ones that do survive it
    /// are drawn as chips above the timed rows, not as rows of their own.
    func refresh() async {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        guard isEnabled, authStatus == .fullAccess else {
            if !upcoming.isEmpty { upcoming = []; onChange?() }
            return
        }

        let now = Date()
        let events = fetch(from: now.addingTimeInterval(-5 * 60), // include the one just started
                           to: now.addingTimeInterval(24 * 3600))
            .filter { $0.endDate > now }
            // Timed events first (sorted by start), all-day after — a 3pm
            // meeting matters more than a day-long "OOO".
            .sorted { a, b in
                if a.isAllDay != b.isAllDay { return !a.isAllDay }
                return a.startDate < b.startDate
            }
            .prefix(3)
            .map(map(_:))

        let next = Array(events)
        let glanceNow = glanceEventWould(be: next)
        if next != upcoming || glanceNow != lastGlance {
            upcoming = next
            lastGlance = glanceNow
            onChange?()
        }
    }

    private func glanceEventWould(be events: [CalendarEvent]) -> Bool {
        let now = Date()
        return events.contains { event in
            !event.isAllDay
                && event.start.timeIntervalSince(now) < 10 * 60
                && now.timeIntervalSince(event.start) < 5 * 60
        }
    }

    /// Open the call, preferring the provider's app over the browser.
    ///
    /// `NSWorkspace.open` returns false when nothing is registered for the
    /// scheme, which is exactly the "app not installed" case — so the https URL
    /// is not a consolation prize, it is the same click finishing correctly.
    /// The handoff can only be attempted, never assumed: see
    /// `MeetingLinks.appURL(for:)` for which providers have one and why.
    func join(_ event: CalendarEvent) {
        guard let meeting = event.meeting else { return }
        if let appURL = meeting.appURL, NSWorkspace.shared.open(appURL) {
            onNavigateAway?()
            return
        }
        NSWorkspace.shared.open(meeting.url)
        onNavigateAway?()
    }

    /// Open Calendar.app (best-effort deep-link to the event, else the app).
    func openInCalendar(_ event: CalendarEvent) {
        if let url = URL(string: "ical://ekevent/\(event.id)?method=show&options=more") {
            NSWorkspace.shared.open(url)
            onNavigateAway?()
        } else {
            openCalendarApp()
        }
    }

    func openCalendarApp() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        onNavigateAway?()
    }
}

/// The one place EventKit's status crosses into the pure diagnosis.
private extension CalendarAuthorization {
    init(_ status: EKAuthorizationStatus) {
        switch status {
        case .notDetermined: self = .notDetermined
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .fullAccess: self = .fullAccess
        case .writeOnly: self = .writeOnly
        // Whatever a later macOS adds.
        default: self = .other
        }
    }
}
