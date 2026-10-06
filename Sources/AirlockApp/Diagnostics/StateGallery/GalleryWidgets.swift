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
/// `init(previewing:)`, which opens no store and runs no `git`.
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
            GalleryState("W46", area, "Shortcut map: asking off, so no \"Hold to ask the notch\"", width: panel) {
                keyMap(dictation: true, asks: false).frame(width: side)
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
        ] + askStripStates
    }

    /// The Ask strip is the guide's, so it is drawn only where the guide is.
    private static var askStripStates: [GalleryState] {
        #if AIRLOCK_GUIDE
        [
            // MARK: Ask strip
            GalleryState("W55", area, "Ask strip: asking off (default)", width: panel) {
                AskStripCard(strip: AskStrip(holdKey: nil, typeKey: nil))
            },
            GalleryState("W56", area, "Ask strip: hold to ask / type", width: panel) {
                AskStripCard(strip: AskStrip(holdKey: HoldKeyMonitor.Key.option.glyph,
                                             typeKey: GlobalHotkey.Binding.optionSpace.displayName))
            },
        ]
        #else
        []
        #endif
    }

    // MARK: - Geometry

    /// The panel's stack is inset 10pt a side (`NotchRootView`), the gallery's
    /// panel ground 14pt — so the ground is widened by the difference, and what
    /// is inside it gets exactly the 620pt stack of the default 640pt panel.
    private static let panel: CGFloat = GalleryState.panelWidth + 2 * (14 - 10)
    private static let stack: CGFloat = GalleryState.panelWidth - 2 * 10
    /// One of two paired columns, 25pt apart.
    private static let side: CGFloat = (stack - 25) / 2

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
    /// `SettingsView` draws its status line: the sentence is the model's.
    private static func waveSettings(_ diagnosis: WaveTapDiagnosis) -> some View {
        Form {
            Section("How should the music bars move?") {
                Toggle("Wave follows the audio", isOn: .constant(true))
                WaveTapStatusLine(status: diagnosis.message(player: "Spotify"), isProblem: diagnosis.isProblem,
                                  needsPermission: diagnosis.needsPermission)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(height: 160)
    }

    // MARK: - Home's controls row

    /// Leading and trailing columns, 25pt apart, each card alone in its column
    /// and so filling the row — Home as `NotchRootView` lays it out.
    private static func homeRow(controls: some View = controlsCard(on: [.wifi]),
                                sound: some View) -> some View {
        HStack(alignment: .top, spacing: 25) {
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
                                     heldForAgents: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ControlRail(shown: shown, isOn: { on.contains($0) }, openStrip: nil)
            if let failure {
                ControlFailureLine(problem: failure)
            } else if heldForAgents {
                ControlNoteLine(symbol: "cup.and.saucer.fill", text: SystemControlsModel.heldForAgentsNote)
            }
        }
        .modifier(HomeCardBackground())
    }

    /// The app's own sentence for a CoreWLAN refusal (macOS's words go to
    /// the log since B1).
    private static var wifiRefusal: String {
        SystemControlsModel.wifiRefused
    }

    private static func keyMap(dictation: Bool, asks: Bool = true) -> some View {
        KeyMapCard(rows: KeyMapSectionView.rows(
            dictation: dictation ? (hold: HoldKeyMonitor.Key.control.glyph,
                                    ask: asks ? HoldKeyMonitor.Key.option.glyph : nil) : nil,
            clipboardKey: GlobalHotkey.Binding.commandShiftC.displayName))
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
