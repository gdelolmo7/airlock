import AppKit
import EventKit
import SwiftUI
import AirlockCore

/// Home and Dashboard widgets (W) of the inventory.
///
/// **Leaf views from values, never a live widget model.** Nearly every model
/// here starts something when it is built or started — Now Playing and
/// MediaRemote, Core Audio listeners and process taps, EventKit, IOKit power
/// notifications, keep-awake assertions — so the cards are drawn the way the
/// snapshot tests draw them (`HomeTabSnapshot`, `LevelsRowsSnapshot`,
/// `SystemSectionSnapshot`): `NowPlayingCard`, `ControlRail`, `LevelRows` and
/// friends with plain values. The two models that are built,
/// `CalendarWidgetModel` and `RepositoryWidgetModel`, go through their
/// `init(previewing:)`, which opens no store and runs no `git`. The Agents
/// tab's usage rows draw on an `AppModel` that is never started, as the Agents
/// area does, and an `AgentsWidgetModel` previewing its values.
///
/// Every sentence is the app's own — a model constant, a Core policy, a static
/// the model itself calls — so a wording change shows up here the same day.
@MainActor
enum GalleryWidgets {
    static let area = "Widgets"

    static var states: [GalleryState] {
        [
            // MARK: Media
            GalleryState("W1", area, "Media: playing", width: panel) {
                nowPlaying(playing: true)
            },
            GalleryState("W2", area, "Media: paused", width: panel) {
                nowPlaying(playing: false)
            },
            GalleryState("W3", area, "Media: no cover", width: panel) {
                NowPlayingCard(title: "Voice Memo 14", artist: "Unknown Artist", playerName: "Music",
                               isPlaying: true,
                               artwork: ArtworkView(url: nil, size: MediaCardMetrics.artworkSize,
                                                    source: .appleMusic),
                               artworkLabel: "Music icon",
                               timeline: timeline(position: 12, duration: 96),
                               onOpen: {}, onPrevious: {}, onTogglePlay: {}, onNext: {})
            },
            GalleryState("W4", area, "Media: live stream", width: panel) {
                NowPlayingCard(title: "Radio Paradise — Main Mix", artist: "Live", playerName: "Music",
                               isPlaying: true, artwork: artwork, artworkLabel: "Album artwork, Music",
                               timeline: timeline(position: 1_712, duration: nil),
                               onOpen: {}, onPrevious: {}, onTogglePlay: {}, onNext: {})
            },
            GalleryState("W5", area, "Media: player quit (last played)", width: panel) {
                dormant(ago: "2 hr. ago")
            },
            GalleryState("W6", area, "Media: player open but stopped (Spotify is still running)", width: panel) {
                dormant(ago: "3 min. ago", isRunning: true)
            },
            GalleryState("W7", area, "Media: nothing playing (no card; Home is the row below)", width: panel) {
                homeRow(sound: soundCard())
            },
            GalleryState("W8", area, "Media: Spotify/Music control refused", width: panel) {
                VStack(alignment: .leading, spacing: 10) {
                    MediaRefusedCard(player: "Spotify")
                    homeRow(sound: soundCard())
                }
            },
            GalleryState("W9", area, "Media: moving wave can't hear audio (Settings)", ground: .window, width: 560) {
                waveSettings(WaveTapDiagnosis.deniedCapture)
            },

            // MARK: Sound
            GalleryState("W10", area, "Sound: one output", width: panel) {
                homeRow(sound: soundCard())
            },
            GalleryState("W11", area, "Sound: several outputs / list open", width: panel) {
                homeRow(sound: soundCard(devices: [speakers, display, "AirPods Pro"], choosing: true))
            },
            GalleryState("W12", area, "Sound: muted", width: panel) {
                homeRow(sound: soundCard(output: output(0.62, muted: true)))
            },
            GalleryState("W13", area, "Sound: HDMI output, no volume to set, nothing playing", width: panel) {
                homeRow(sound: soundCard(device: display, output: nil))
            },
            GalleryState("W14", area, "Sound: per-app levels", width: panel) {
                homeRow(sound: soundCard(apps: [app("Music", 1.0), app("Safari", 0.45)]))
            },
            GalleryState("W15", area, "Sound: app went quiet", width: panel) {
                homeRow(sound: soundCard(apps: [app("Music", 0.8), app("Safari", 0.45, idle: true)]))
            },
            GalleryState("W16", area, "Sound: per-app level can't apply (the permission, said once)", width: panel) {
                homeRow(sound: soundCard(apps: [app("Safari", 0.4, failure: AppVolumeModel.levelNotApplied)]))
            },
            GalleryState("W17", area, "Sound: more than four apps", width: panel) {
                homeRow(sound: soundCard(apps: [app("Music", 1.0), app("Podcasts", 0.35, muted: true),
                                                app("Safari", 0.7), app("TV", 0.5)], hidden: 1))
            },
            GalleryState("W18", area, "Sound: Multi-Output Device", width: panel) {
                homeRow(sound: soundCard(device: "Multi-Output Device", output: nil,
                                         apps: [app("Safari", 0.6, failure: AppVolumeTap.multiOutputRefusal),
                                                app("TV", 0.45, failure: AppVolumeTap.multiOutputRefusal)]))
            },

            // MARK: Calendar
            calendar("W19", "Calendar: never asked", CalendarWidgetModel(previewing: .notDetermined)),
            calendar("W20", "Calendar: denied", CalendarWidgetModel(previewing: .denied)),
            calendar("W21", "Calendar: managed by your company", CalendarWidgetModel(previewing: .restricted)),
            calendar("W22", "Calendar: add-only access",
                     CalendarWidgetModel(previewing: .writeOnly)),
            calendar("W23", "Calendar: you declined",
                     CalendarWidgetModel(previewing: .denied, outcome: .declined)),
            calendar("W24", "Calendar: no meetings", CalendarWidgetModel(previewing: .fullAccess)),
            calendar("W24a", "Calendar: no calendars ticked",
                     CalendarWidgetModel(previewing: .fullAccess, selection: CalendarSelection(chosen: []))),
            calendar("W25", "Calendar: picked day empty",
                     CalendarWidgetModel(previewing: .fullAccess, selectedDay: day(2),
                                         daysWithEvents: [day(0), day(1)])),
            calendar("W26", "Calendar: header on a picked day",
                     CalendarWidgetModel(previewing: .fullAccess, selectedDay: day(1),
                                         dayEvents: [event("Design review", at: day(1), hour: 10, color: .systemPurple,
                                                           zoom: true),
                                                     event("1:1 with Sam", at: day(1), hour: 15, color: .systemBlue)],
                                         daysWithEvents: [day(0), day(1)])),
            calendar("W27", "Calendar: events (all-day, past, now, soon, later) on today",
                     CalendarWidgetModel(previewing: .fullAccess, selectedDay: day(0),
                                         dayEvents: todaysEvents, daysWithEvents: [day(0), day(1)])),
            calendar("W28", "Calendar: loading a day",
                     CalendarWidgetModel(previewing: .fullAccess, selectedDay: day(1),
                                         daysWithEvents: [day(0), day(1)], isLoadingDay: true)),
            calendar("W29", "Calendar: refusal on file",
                     CalendarWidgetModel(previewing: .denied, outcome: .standingDenial)),
            calendar("W30", "Calendar: macOS never showed the dialog",
                     CalendarWidgetModel(previewing: .denied, outcome: .promptSuppressed)),

            // MARK: Battery
            GalleryState("W31", area, "Battery: normal / low / hidden %") {
                HStack(alignment: .top, spacing: 34) {
                    battery("normal", BatteryState(percentage: 76, isCharging: false, isCharged: false,
                                                   isPluggedIn: false, minutesRemaining: 312))
                    battery("low", BatteryState(percentage: 14, isCharging: false, isCharged: false,
                                                isPluggedIn: false, minutesRemaining: 38))
                    battery("% hidden", BatteryState(percentage: 76, isCharging: false, isCharged: false,
                                                     isPluggedIn: false, minutesRemaining: 312), percentage: false)
                }
            },
            GalleryState("W32", area, "Battery: charging, at 5%") {
                battery("charging", BatteryState(percentage: 5, isCharging: true, isCharged: false,
                                                 isPluggedIn: true, minutesRemaining: 140))
            },
            GalleryState("W33", area, "Battery: plugged in, holding (optimised charging)") {
                battery("holding at 80%", BatteryState(percentage: 80, isCharging: false, isCharged: false,
                                                       isPluggedIn: true, minutesRemaining: nil))
            },

            // MARK: System controls
            GalleryState("W34", area, "System controls: the six buttons", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi, .awake]), sound: soundCard())
            },
            GalleryState("W35", area, "System controls: every button hidden (the shortcut map takes the column)",
                         width: panel) {
                // `SystemControlsWidget.panelSection` is nil with an empty
                // rail, so the column's fallback draws instead.
                homeRow(controls: keyMap(dictation: false), sound: soundCard())
            },
            GalleryState("W36", area, "Wi-Fi: refused", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi], failure: .init(sentence: wifiRefusal)),
                        sound: soundCard())
            },
            GalleryState("W37", area, "Wi-Fi: no hardware", width: panel) {
                homeRow(controls: controlsCard(on: [], failure: .init(sentence: SystemControlsModel.noWiFi)),
                        sound: soundCard())
            },
            GalleryState("W38", area, "Awake: stopped by battery (goes 5 min after first seen)", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi],
                                               failure: .init(sentence: KeepAwakePolicy.stoppedMessage(cutoff: 50))),
                        sound: soundCard())
            },
            GalleryState("W39", area, "Awake: kept awake for agents (cup in the island, button off, line says why)",
                         width: panel) {
                VStack(alignment: .leading, spacing: 14) {
                    caption("closed island")
                    HStack(spacing: 8) {
                        Spacer(minLength: 0)
                        KeepAwakeCup()
                    }
                    .padding(.horizontal, 12)
                    .frame(width: 130, height: 32)
                    .background(Color.white.opacity(0.06), in: .rect(cornerRadius: 10))
                    caption("open panel")
                    homeRow(controls: controlsCard(on: [.wifi], heldForAgents: true), sound: soundCard())
                }
            },
            // Keep awake for a set time. The next free IDs, kept beside the
            // other awake rows.
            GalleryState("W57", area, "Awake: how-long menu open (menu button beside the cup, or a right-click)",
                         width: panel) {
                VStack(alignment: .leading, spacing: 14) {
                    caption("beside Sound")
                    homeRow(controls: controlsCard(on: [.wifi], awakeStrip: awakeStrip()), sound: soundCard())
                    caption("alone in the row")
                    controlsCard(on: [.wifi], awakeStrip: awakeStrip()).frame(width: stack)
                }
            },
            GalleryState("W58", area, "Awake: on for a set time, 42 min left, with +30 min", width: panel) {
                VStack(alignment: .leading, spacing: 14) {
                    homeRow(controls: controlsCard(on: [.wifi, .awake], countdown: countdown(left: 42 * 60)),
                            sound: soundCard())
                    caption("over an hour")
                    homeRow(controls: controlsCard(on: [.wifi, .awake], countdown: countdown(left: 80 * 60)),
                            sound: soundCard())
                }
            },
            GalleryState("W59", area, "Awake: on for a set time, under a minute left", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi, .awake], countdown: countdown(left: 40)),
                        sound: soundCard())
            },
            GalleryState("W60", area, "Awake: \"Until…\" set to 08:00, picked at 23:00 (tomorrow)", width: panel) {
                VStack(alignment: .leading, spacing: 14) {
                    caption("beside Sound")
                    homeRow(controls: controlsCard(on: [.wifi], awakeStrip: awakeStrip(until: eightOClock)),
                            sound: soundCard())
                    caption("alone in the row")
                    controlsCard(on: [.wifi], awakeStrip: awakeStrip(until: eightOClock)).frame(width: stack)
                }
            },
            GalleryState("W61", area, "Awake: the set time ran out (quiet line, no sound, goes 5 min after first seen)",
                         width: panel) {
                homeRow(controls: controlsCard(on: [.wifi],
                                               failure: .init(sentence: KeepAwakeTimer.endedMessage, isNote: true)),
                        sound: soundCard())
            },
            GalleryState("W40", area, "Dark mode: not allowed", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi],
                                               failure: .init(sentence: SystemControlsModel.appearanceRefused,
                                                              pane: .automation)),
                        sound: soundCard())
            },
            GalleryState("W41", area, "Screenshot: no Screen Recording", width: panel) {
                homeRow(controls: controlsCard(on: [.wifi],
                                               failure: .init(sentence: SystemControlsModel.screenshotNeedsPermission,
                                                              pane: .permission(.screenRecording))),
                        sound: soundCard())
            },
            GalleryState("W42", area, "Record: no Screen Recording / recorder didn't start", width: panel) {
                VStack(alignment: .leading, spacing: 14) {
                    homeRow(controls: controlsCard(on: [.wifi],
                                                   failure: .init(sentence: SystemControlsModel.recordingNeedsPermission,
                                                                  pane: .permission(.screenRecording))),
                            sound: soundCard())
                    homeRow(controls: controlsCard(on: [.wifi],
                                                   failure: .init(sentence: SystemControlsModel.recorderDidNotStart)),
                            sound: soundCard())
                }
            },

            // MARK: Shortcut map
            GalleryState("W43", area, "Shortcut map", width: panel) {
                homeRow(controls: keyMap(dictation: false), sound: soundCard())
            },
            GalleryState("W44", area, "Shortcut map: dictation row", width: panel) {
                homeRow(controls: keyMap(dictation: true), sound: soundCard())
            },
            GalleryState("W45", area, "Shortcut map: clipboard and shelf rows", width: panel) {
                keyMap(dictation: false).frame(width: side)
            },

            // MARK: Try these
            GalleryState("W78", area, "Try these: a new Mac, nothing done yet", width: panel) {
                tryThese(done: [], dictation: true, calendar: true)
            },
            GalleryState("W79", area, "Try these: two done, no dictation, no calendar", width: panel) {
                tryThese(done: [.copyTwice], dictation: false, calendar: false)
            },
            GalleryState("W80", area, "Try these: above the music and the controls", width: panel) {
                VStack(spacing: PanelStackMetrics.columnGap) {
                    tryThese(done: [.copyTwice, .dropFile], dictation: true, calendar: true)
                    homeRow(sound: soundCard())
                }
            },

            // MARK: System stats
            GalleryState("W47", area, "System stats: normal", width: panel) {
                SystemStatsContent(stats: SystemStats(cpuPercent: 23.6, memoryPercent: 64.8, memoryUsedGB: 31.1,
                                                      memoryTotalGB: 48, gpuPercent: 12),
                                   apps: .breakdown(ranked([xcode: 14.2, node: 4.1, .spotlight: 2.3], 23.6)))
                    .frame(width: side)
                    .modifier(Settled())
            },
            GalleryState("W48", area, "System stats: first seconds (before the first figures)", width: panel) {
                SystemStatsContent(stats: nil, apps: .measuring)
                    .frame(width: side)
                    .modifier(Settled())
            },
            GalleryState("W49", area, "System stats: no GPU figure, idle Mac", width: panel) {
                SystemStatsContent(stats: SystemStats(cpuPercent: 0.8, memoryPercent: 42.0, memoryUsedGB: 20.2,
                                                      memoryTotalGB: 48, gpuPercent: nil),
                                   apps: .breakdown(ranked([node: 0.3], 0.8)))
                    .frame(width: side)
                    .modifier(Settled())
            },
            GalleryState("W50", area, "System stats: busiest apps", width: panel) {
                SystemStatsContent(stats: SystemStats(cpuPercent: 87.4, memoryPercent: 81.3, memoryUsedGB: 39.0,
                                                      memoryTotalGB: 48, gpuPercent: 64),
                                   apps: .breakdown(ranked([xcode: 41.2, .simulator: 22.8, .spotlight: 9.6,
                                                            node: 0.6], 87.4)))
                    .frame(width: side)
                    .modifier(Settled())
            },

            // MARK: Repository
            repository("W51", "Repository: clean / changed / ahead", [
                repo("airlock", GitStatus(branch: "main", hasUpstream: true)),
                repo("website", GitStatus(branch: "feel/home-cards", changed: 3, untracked: 2)),
                repo("homebrew-tap", GitStatus(branch: "bump/652", ahead: 2, behind: 1, changed: 1,
                                               hasUpstream: true)),
            ]),
            repository("W52", "Repository: detached", [
                repo("airlock", GitStatus(branch: nil, changed: 1)),
            ]),
            .notYet("W53", area, "Repository: same facts in the session row",
                    why: "The session row's half needs AppModel and a live session (the Agents area); the widget's half is W51."),
            repository("W54", "Repository: mid-rebase with a conflict (git's own output, parsed)", [
                repo("airlock", {
                    var status = GitStatusParser.parse("""
                        # branch.oid 534fbd1c2e
                        # branch.head (detached)
                        u UU N... 100644 100644 100644 100644 a1 b2 c3 Sources/AirlockApp/AppDelegate.swift
                        1 M. N... 100644 100644 100644 d4 e5 docs/feel-and-finish-inventory.md
                        """)
                    status.operation = GitOperation.inProgress(markers: ["rebase-merge"])
                    return status
                }()),
            ]),

            // MARK: Calls
            GalleryState("W62", area, "Calls tab: today, yesterday and an older day, mixed apps",
                         width: panel) {
                callsTab(mixedCalls, week: 5)
            },
            GalleryState("W63", area, "Calls tab: six calls, the most it shows", width: panel) {
                callsTab(sixCalls, week: 9)
            },
            GalleryState("W64", area, "Calls tab: one call", width: panel) {
                callsTab([call("Call with Sam", day: 0, at: 9.5, minutes: 12, todos: 1, in: whatsApp)], week: 1)
            },
            GalleryState("W65", area, "Calls tab: call notes on, no calls yet", width: panel) {
                callsTab([])
            },
            GalleryState("W70", area, "Calls tab: \"Take notes\" for a meeting in the room", width: panel) {
                callsTab(mixedCalls, week: 5, hand: .takeNotes)
            },
            // No row for the call on the tab: the card above the tabs has
            // it, with the clock, the window, Pause and Stop.
            GalleryState("W71", area, "Calls tab: taking notes of a call, the card above the tab",
                         width: panel) {
                underNotesCard(paused: false, callsTab(mixedCalls, week: 5, takingNotes: true, hand: .stop))
            },
            GalleryState("W73", area, "Calls tab: notes paused", width: panel) {
                underNotesCard(paused: true, callsTab(mixedCalls, week: 5, takingNotes: true, hand: .stop))
            },
            GalleryState("W74", area, "Calls tab: first call, notes being taken, nothing saved yet",
                         width: panel) {
                underNotesCard(paused: false, callsTab([], takingNotes: true, hand: .stop))
            },
            GalleryState("W72", area, "Calls tab: no calls yet, \"Take notes\"", width: panel) {
                callsTab([], hand: .takeNotes)
            },
            // A recording somebody already has: "Add recording" beside "Take
            // notes", and the one being read on top while it is.
            GalleryState("W75", area, "Calls tab: \"Add recording\" beside \"Take notes\"", width: panel) {
                callsTab(mixedCalls, week: 5, hand: .takeNotes, addsRecordings: true)
            },
            GalleryState("W76", area, "Calls tab: a recording being read, its row on top", width: panel) {
                callsTab(mixedCalls, week: 5, hand: .takeNotes, addsRecordings: true,
                         reading: GalleryMeetings.reading(.listening, heard: 14 * 60))
            },
            GalleryState("W77", area, "Calls tab: no calls yet, \"Take notes\" and \"Add recording\"",
                         width: panel) {
                callsTab([], hand: .takeNotes, addsRecordings: true)
            },
            GalleryState("W66", area, "Dashboard: call notes on (no Calls card)", width: panel) {
                dashboard
            },

            // MARK: Claude usage, on the Agents tab
            GalleryState("W67", area, "Agents tab: Claude usage figures (tooltip not drawn)", width: panel) {
                agentsTab(usage: freshUsage)
            },
            GalleryState("W68", area, "Agents tab: usage figures 2 h old, dated", width: panel) {
                agentsTab(usage: staleUsage)
            },
            GalleryState("W69", area, "Agents tab: no usage figures, so no line", width: panel) {
                agentsTab(usage: nil)
            },
        ]
    }

    // MARK: - Geometry

    /// The panel's stack is inset 10pt a side (`NotchRootView`), the gallery's
    /// panel ground 14pt — so the ground is widened by the difference, and what
    /// is inside it gets exactly the 620pt stack of the default 640pt panel.
    private static let panel: CGFloat = GalleryState.panelWidth + 2 * (14 - 10)
    private static let stack: CGFloat = GalleryState.panelWidth - 2 * 10
    /// One of two paired columns, `PanelStackMetrics.columnGap` apart.
    private static let side: CGFloat = (stack - PanelStackMetrics.columnGap) / 2

    // MARK: - Media

    /// A flat stand-in cover: `ArtworkView` loads a remote image, which a
    /// picture taken on the spot cannot wait for.
    private static var artwork: some View {
        RoundedRectangle(cornerRadius: MediaCardMetrics.artworkSize * 0.22, style: .continuous)
            .fill(LinearGradient(colors: [.purple, .orange], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: MediaCardMetrics.artworkSize, height: MediaCardMetrics.artworkSize)
    }

    private static func timeline(position: TimeInterval, duration: TimeInterval?) -> MediaTimelineRow {
        MediaTimelineRow(position: position, duration: duration, isSeekable: duration != nil,
                         onBegin: { _ in }, onMove: { _ in }, onEnd: { _ in })
    }

    private static func nowPlaying(playing: Bool) -> some View {
        NowPlayingCard(title: "Midnight City", artist: "M83", playerName: "Spotify", isPlaying: playing,
                       artwork: artwork, artworkLabel: "Album artwork, Spotify",
                       timeline: timeline(position: 37, duration: 245),
                       onOpen: {}, onPrevious: {}, onTogglePlay: {}, onNext: {})
    }

    /// The caption and button `MediaSectionView` builds, with a fixed "ago".
    private static func dormant(ago: String, isRunning: Bool = false) -> some View {
        DormantTrackCard(title: "Midnight City", artist: "M83",
                         caption: MediaWidgetModel.dormantCaption(player: "Spotify", ago: ago, isRunning: isRunning),
                         button: MediaWidgetModel.dormantButton(player: "Spotify", isRunning: isRunning),
                         artwork: artwork, onReopen: {})
    }

    /// Settings' "How should the music bars move?" section, drawn as
    /// Settings draws its status line: the sentence is the model's.
    private static func waveSettings(_ diagnosis: WaveTapDiagnosis) -> some View {
        LookColumn {
            LookToggleRow("Wave follows the audio", isOn: .constant(true))
            WaveTapStatusLine(status: diagnosis.message(player: "Spotify"), isProblem: diagnosis.isProblem,
                              needsPermission: diagnosis.needsPermission)
        }
    }

    // MARK: - Home's controls row

    /// Leading and trailing columns, a column gap apart, each card alone in its column
    /// and so filling the row — Home as `NotchRootView` lays it out.
    private static func homeRow(controls: some View = controlsCard(on: [.wifi]),
                                sound: some View) -> some View {
        HStack(alignment: .top, spacing: PanelStackMetrics.columnGap) {
            controls.frame(width: side)
            sound.frame(width: side)
        }
        .fixedSize(horizontal: false, vertical: true)
        .environment(\.fillsPairedRow, true)
    }

    /// `SystemControlsSectionView` from values: the rail, and the line saying
    /// why the last press did nothing.
    private static func controlsCard(shown: [SystemControlsModel.Control] = SystemControlsModel.Control.allCases,
                                     on: Set<SystemControlsModel.Control>,
                                     failure: SystemControlsModel.Problem? = nil,
                                     heldForAgents: Bool = false,
                                     awakeStrip: KeepAwakeStrip? = nil,
                                     countdown: KeepAwakeCountdownLine? = nil) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlRail(shown: shown, isOn: { on.contains($0) }, openStrip: awakeStrip == nil ? nil : .awake)
            if let awakeStrip { awakeStrip }
            if let countdown { countdown }
            if let failure {
                ControlFailureLine(problem: failure)
            } else if heldForAgents {
                ControlNoteLine(symbol: "cup.and.saucer.fill", text: SystemControlsModel.heldForAgentsNote)
            }
        }
        .modifier(HomeCardBackground())
    }

    /// Eleven at night today, so "Until…" set to 08:00 reads as tomorrow
    /// whenever the gallery is drawn.
    private static var lateEvening: Date {
        Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: Date()) ?? Date()
    }

    private static let eightOClock = KeepAwakeTimer.TimeOfDay(hour: 8, minute: 0)

    /// The awake strip as the section builds it: the chips, or with `until`
    /// the "Until…" clock already set to it.
    private static func awakeStrip(until: KeepAwakeTimer.TimeOfDay? = nil) -> KeepAwakeStrip {
        KeepAwakeStrip(suggested: eightOClock, settingUntil: until, frozenNow: lateEvening, pick: { _ in })
    }

    /// The countdown line, stopped `left` seconds before its end.
    private static func countdown(left: TimeInterval) -> KeepAwakeCountdownLine {
        let now = Date()
        return KeepAwakeCountdownLine(deadline: now.addingTimeInterval(left), frozenNow: now, add: {})
    }

    /// The app's own sentence for a CoreWLAN refusal (macOS's words go to
    /// the log since B1).
    private static var wifiRefusal: String {
        SystemControlsModel.wifiRefused
    }

    private static func keyMap(dictation: Bool) -> some View {
        KeyMapCard(rows: KeyMapSectionView.rows(
            dictation: dictation ? HoldKeyMonitor.Key.control.glyph : nil,
            clipboardKey: GlobalHotkey.Binding.commandShiftC.displayName))
    }

    private static func tryThese(done: Set<FirstStep>, dictation: Bool, calendar: Bool) -> some View {
        let available = FirstStepsCard.available(dictation: dictation, calendar: calendar)
        return FirstStepsCard(steps: FirstSteps(startedAt: Date()).steps(available: available),
                              done: done, holdKey: HoldKeyMonitor.Key.control.displayName, onHide: {})
            .frame(width: stack)
    }

    // MARK: - Sound

    private static let speakers = "MacBook Pro Speakers"
    private static let display = "LG HDR 4K"

    /// `SoundSectionView` from values, stretched beside the controls.
    private static func soundCard(device: String = speakers, devices: [String] = [],
                                  choosing: Bool = false, output: LevelSource? = output(0.62),
                                  apps: [LevelSource] = [], hidden: Int = 0) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SoundCardHeader(device: device, canSwitch: devices.count > 1, isChoosing: choosing, stacked: true)
            if choosing {
                OutputDeviceList(choices: devices.map { OutputChoice(id: $0, name: $0, isCurrent: $0 == device) })
            }
            Spacer(minLength: 0)
            if output == nil && apps.isEmpty { OwnVolumeNote() }
            // As `FaderConsoleView` builds them: the rows drop the
            // Multi-Output refusal, and the card says it once underneath.
            VStack(alignment: .leading, spacing: 6) {
                LevelRows(output: output,
                          apps: apps.map(rowAsDrawn),
                          hidden: hidden)
                LevelsNotice(notice: AppVolumeModel.cardNotice(failures: apps.compactMap(\.failure)))
            }
        }
        .modifier(HomeCardBackground())
    }

    /// The row with the caption `FaderConsoleView.appLevel` would give it.
    private static func rowAsDrawn(_ row: LevelSource) -> LevelSource {
        LevelSource(id: row.id, name: row.name, value: row.value, isMuted: row.isMuted, isIdle: row.isIdle,
                    icon: row.icon, symbol: row.symbol, mute: row.mute,
                    failure: AppVolumeModel.rowFailure(row.failure), set: row.set)
    }

    private static func output(_ value: Double, muted: Bool = false) -> LevelSource {
        LevelSource(id: "output", name: "Volume", value: value, isMuted: muted, isIdle: false, icon: nil,
                    symbol: OutputMute.isSilent(volume: Float(value), isMuted: muted)
                        ? "speaker.slash.fill" : "speaker.wave.2.fill",
                    mute: (name: muted ? "Unmute" : "Mute", run: {}), failure: nil, set: { _ in })
    }

    private static let appPaths: [String: String] = [
        "Music": "/System/Applications/Music.app",
        "Podcasts": "/System/Applications/Podcasts.app",
        "Safari": "/Applications/Safari.app",
        "TV": "/System/Applications/TV.app",
    ]

    private static func app(_ name: String, _ value: Double, muted: Bool = false, idle: Bool = false,
                            failure: String? = nil) -> LevelSource {
        LevelSource(id: name, name: name, value: value, isMuted: muted, isIdle: idle,
                    icon: appPaths[name].map { NSWorkspace.shared.icon(forFile: $0) },
                    symbol: "app.dashed",
                    mute: idle ? nil : (name: muted ? "Unmute" : "Mute", run: {}),
                    failure: failure, set: { _ in })
    }

    // MARK: - Calendar

    /// The Dashboard's leading column, as `CalendarWidget` puts it there.
    private static func calendar(_ id: String, _ name: String, _ model: CalendarWidgetModel) -> GalleryState {
        GalleryState(id, area, name, width: panel) {
            CalendarSectionView()
                .environment(model)
                .frame(width: side, alignment: .leading)
        }
    }

    /// Start of the day `offset` days from today. Relative to the clock, since
    /// the strip and the rows read it: the picture is "today", whenever today is.
    private static func day(_ offset: Int) -> Date {
        let cal = Calendar.current
        return cal.date(byAdding: .day, value: offset, to: cal.startOfDay(for: Date())) ?? Date()
    }

    private static func event(_ title: String, at day: Date, hour: Double, length: Double = 1,
                              color: NSColor, zoom: Bool = false, allDay: Bool = false) -> CalendarEvent {
        let start = allDay ? day : day.addingTimeInterval(hour * 3600)
        return CalendarEvent(id: title, title: title, start: start,
                             end: allDay ? day.addingTimeInterval(86_400) : start.addingTimeInterval(length * 3600),
                             calendarID: "work", color: color,
                             meeting: zoom ? MeetingLinks.detect(url: "https://zoom.us/j/81234567890",
                                                                 location: nil, notes: nil) : nil,
                             isAllDay: allDay)
    }

    /// One of each kind, around the clock: finished, running, in a few
    /// minutes (the amber Join), and later.
    private static var todaysEvents: [CalendarEvent] {
        let now = Date()
        func at(_ offset: TimeInterval, _ title: String, length: Double, color: NSColor,
                zoom: Bool = false) -> CalendarEvent {
            CalendarEvent(id: title, title: title, start: now.addingTimeInterval(offset),
                          end: now.addingTimeInterval(offset + length * 3600), calendarID: "work", color: color,
                          meeting: zoom ? MeetingLinks.detect(url: "https://meet.google.com/abc-defg-hij",
                                                              location: nil, notes: nil) : nil,
                          isAllDay: false)
        }
        return [
            event("Offsite week", at: day(0), hour: 0, color: .systemGreen, allDay: true),
            at(-3 * 3600, "Stand-up", length: 0.25, color: .systemBlue),
            at(-20 * 60, "Pairing", length: 1, color: .systemOrange),
            at(7 * 60, "Design review", length: 0.5, color: .systemPurple, zoom: true),
            at(3 * 3600, "Dentist", length: 1, color: .systemRed),
        ]
    }

    // MARK: - Battery

    private static func battery(_ label: String, _ state: BatteryState, percentage: Bool = true) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            BatteryGutterView(state: state, showsPercentage: percentage)
            caption(label)
            // The tooltip, which a picture cannot hover for.
            Text("“\(state.spoken)”")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.5))
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: 160, alignment: .leading)
        }
    }

    // MARK: - System stats

    private static let xcode = ProcessGroup(kind: .app, name: "Xcode",
                                            bundlePath: NSWorkspace.shared.urlForApplication(
                                                withBundleIdentifier: "com.apple.dt.Xcode")?.path
                                                ?? "/Applications/Xcode.app")
    private static let node = ProcessGroup(kind: .program, name: "node")

    private static func ranked(_ shares: [ProcessGroup: Double], _ headline: Double) -> CPUBreakdown {
        var ranker = CPUBreakdownRanker()
        return ranker.rank(shares: shares, headline: headline)
    }

    /// The rings sweep in from empty when they appear, and a picture taken on
    /// the spot catches them at nothing: the sweep lands at once instead.
    private struct Settled: ViewModifier {
        func body(content: Content) -> some View {
            content.transaction { $0.animation = nil; $0.disablesAnimations = true }
        }
    }

    // MARK: - Calls

    /// 17:00 today: the made-up calls sit at fixed hours before it, so the
    /// tab says "Today" and "Yesterday" whenever the gallery runs.
    private static var callsNow: Date { day(0).addingTimeInterval(17 * 3600) }

    /// The app a made-up call was in, and the site when it was a browser tab.
    private typealias CallApp = (bundleID: String, site: MeetingLink.Provider?)
    private static let meetInChrome: CallApp = ("com.google.Chrome", .googleMeet)
    private static let whatsApp: CallApp = ("net.whatsapp.WhatsApp", nil)
    private static let zoom: CallApp = ("us.zoom.xos", .zoom)
    private static let safari: CallApp = ("com.apple.Safari", nil)
    private static let slack: CallApp = ("com.tinyspeck.slackmacgap", nil)

    /// A made-up call: a name, when, how long, how many to-dos it left, and
    /// the app it was in. Rows from values, read from no folder.
    private static func call(_ title: String, day offset: Int, at hour: Double, minutes: Double,
                             todos: Int, in app: CallApp = zoom, people: Int = 2) -> CallsCard.Row {
        let start = day(offset).addingTimeInterval(hour * 3600)
        return CallsCard.Row(folder: title, title: title, startedAt: start,
                             endedAt: start.addingTimeInterval(minutes * 60), todos: todos,
                             bundleID: app.bundleID, site: app.site, people: people)
    }

    /// Three days, one call in a browser with no site the logos know, and a
    /// name too long for its row.
    private static var mixedCalls: [CallsCard.Row] {
        [
            call("Budget review", day: 0, at: 14.5, minutes: 42, todos: 3, in: meetInChrome, people: 5),
            call("Call with Ana", day: 0, at: 11.25, minutes: 18, todos: 0, in: whatsApp),
            call("Quarterly planning with design, research, marketing, sales and the partners "
                 + "from the Lisbon office", day: -1, at: 16, minutes: 55, todos: 1, in: zoom, people: 8),
            call("Interview: product designer", day: -4, at: 10, minutes: 47, todos: 2, in: safari, people: 3),
        ]
    }

    /// As many as the tab holds (`CallsCard.limit`): a busy two days.
    private static var sixCalls: [CallsCard.Row] {
        [
            call("Budget review", day: 0, at: 14.5, minutes: 42, todos: 3, in: meetInChrome, people: 5),
            call("Call with Ana", day: 0, at: 11.25, minutes: 18, todos: 0, in: whatsApp),
            call("Stand-up", day: 0, at: 9.5, minutes: 14, todos: 1, in: slack, people: 6),
            call("Supplier check-in", day: -1, at: 17, minutes: 25, todos: 0, in: zoom),
            call("Design review", day: -1, at: 12, minutes: 61, todos: 4, in: meetInChrome, people: 4),
            call("Call with Mum", day: -1, at: 9, minutes: 33, todos: 0, in: whatsApp),
        ]
    }

    /// Where `CallsWidget` puts it: a tab of its own, the stack's whole width.
    private static func callsTab(_ rows: [CallsCard.Row], week: Int = 0, takingNotes: Bool = false,
                                 hand: MeetingNotesFlow.HandButton? = nil, addsRecordings: Bool = false,
                                 reading: RecordingImporter.Reading? = nil) -> some View {
        CallsCardContent(rows: rows, week: week, takingNotes: takingNotes, now: callsNow, hand: hand,
                         reading: reading, onAddRecording: addsRecordings ? {} : nil)
            .frame(width: stack, alignment: .topLeading)
    }

    /// The tab under the card notes are being taken in, as `NotchRootView`
    /// stacks them: the card has the call, so the tab draws no row for it.
    private static func underNotesCard(paused: Bool, _ tab: some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            GalleryCallNotesPanel.takingNotesOfWeekly(paused: paused)
            tab
        }
        .frame(width: stack, alignment: .topLeading)
    }

    /// The Dashboard as `NotchRootView` lays it out with call notes on: the
    /// calendar and System side by side, as before there were call notes,
    /// since the calls have a tab of their own.
    private static var dashboard: some View {
        HStack(alignment: .top, spacing: PanelStackMetrics.columnGap) {
            CalendarSectionView()
                .environment(CalendarWidgetModel(previewing: .fullAccess, selectedDay: day(0),
                                                 dayEvents: todaysEvents, daysWithEvents: [day(0), day(1)]))
                .frame(width: side, alignment: .topLeading)
            SystemStatsContent(stats: SystemStats(cpuPercent: 23.6, memoryPercent: 64.8, memoryUsedGB: 31.1,
                                                  memoryTotalGB: 48, gpuPercent: 12),
                               apps: .breakdown(ranked([xcode: 14.2, node: 4.1, .spotlight: 2.3], 23.6)))
                .frame(width: side)
                .modifier(Settled())
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Claude usage

    /// The Agents tab as `AgentSessionsSectionView` draws it with nothing
    /// running and the figures switched on, so whether there is a line is up
    /// to how old they are.
    private static func agentsTab(usage: UsageSnapshot?) -> some View {
        let model = AppModel()
        model.usage = usage
        let agents = AgentsWidgetModel(previewing: .hooksInstalled)
        agents.wantsUsage = { true }
        return AgentSessionsSectionView()
            .environment(model)
            .environment(agents)
            .environment(RepositoryWidgetModel(previewing: []))
            .environment(NotchUIState())
            .environment(LicenseModel(previewing: .trialing(daysRemaining: 20)))
            .frame(width: stack, alignment: .topLeading)
    }

    private static let freshUsage = UsageSnapshot(
        fiveHour: RateLimitWindow(usedPercentage: 42, resetsAt: Date().addingTimeInterval(3 * 3600)),
        sevenDay: RateLimitWindow(usedPercentage: 76, resetsAt: Date().addingTimeInterval(4 * 86400)),
        capturedAt: Date().addingTimeInterval(-2 * 60))
    private static let staleUsage = UsageSnapshot(
        fiveHour: RateLimitWindow(usedPercentage: 42, resetsAt: Date().addingTimeInterval(3 * 3600)),
        sevenDay: RateLimitWindow(usedPercentage: 76, resetsAt: Date().addingTimeInterval(4 * 86400)),
        capturedAt: Date().addingTimeInterval(-2 * 3600))

    // MARK: - Repository

    private static func repo(_ name: String, _ status: GitStatus) -> RepositoryWidgetModel.Repository {
        RepositoryWidgetModel.Repository(root: URL(fileURLWithPath: "/Users/you/Code/\(name)"), status: status)
    }

    /// On the Agents tab, full width.
    private static func repository(_ id: String, _ name: String,
                                   _ rows: [RepositoryWidgetModel.Repository]) -> GalleryState {
        GalleryState(id, area, name, width: panel) {
            RepositorySectionView()
                .environment(RepositoryWidgetModel(previewing: rows))
        }
    }

    // MARK: - Labels

    private static func caption(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .foregroundStyle(.white.opacity(0.35))
    }
}
