import XCTest
@testable import AirlockCore

final class CompactIslandTests: XCTestCase {
    /// Every case starts from the same fixed instant. `now` has no default —
    /// Core owns no clock — so this helper is where the tests answer "against
    /// which instant?", once, and the timing cases below move relative to it.
    private func input(_ build: (inout CompactIslandInput) -> Void) -> CompactIslandInput {
        var i = CompactIslandInput(now: Self.anchor)
        build(&i)
        return i
    }

    // MARK: - The bug this type exists to prevent

    /// Attention takes BOTH halves and displaces music while it lasts. That is
    /// the intended trade — it is the one state worth interrupting for — and it
    /// is only defensible while nothing sets the state spuriously, which is what
    /// the rest of this file is really guarding.
    func testAttentionTakesBothHalvesAndDisplacesMusic() {
        let i = input {
            $0.agentsEnabled = true; $0.attentionCount = 1; $0.sessionCount = 2
            $0.hasMedia = true; $0.mediaPlaying = true
        }
        XCTAssertEqual(CompactIsland.trailing(i), .attentionDot)
        XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: true, working: false))
    }

    /// The other half of that bargain: the moment nothing needs answering, the
    /// island gives the slot straight back. A stale gate holding it is the bug
    /// this pairs with — see `testNothingWaitingMeansNoAmberAnywhere`.
    func testMusicReturnsAsSoonAsAttentionClears() {
        let i = input {
            $0.agentsEnabled = true; $0.attentionCount = 0; $0.sessionCount = 2
            $0.anyRunning = true; $0.hasMedia = true; $0.mediaPlaying = true
        }
        XCTAssertEqual(CompactIsland.trailing(i), .wave)
        XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: false, working: true))
    }

    /// Sessions merely WORKING must never read as amber. A running agent is not
    /// waiting for you, and if it looked like it was, the colour would stop
    /// meaning anything.
    func testNothingWaitingMeansNoAmberAnywhere() {
        for sessions in 1...4 {
            let i = input {
                $0.agentsEnabled = true; $0.sessionCount = sessions; $0.anyRunning = true
            }
            XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: false, working: true),
                           "\(sessions) working sessions")
            XCTAssertNotEqual(CompactIsland.trailing(i), .attentionDot)
        }
    }

    /// Attention must never be silent just because it left the trailing slot.
    func testAttentionIsAlwaysShownSomewhere() {
        for playing in [true, false] {
            for meeting in [true, false] {
                for enabled in [true, false] {
                    let i = input {
                        $0.agentsEnabled = enabled; $0.attentionCount = 1; $0.sessionCount = 1
                        $0.mediaPlaying = playing; $0.hasMedia = playing; $0.meetingSoon = meeting
                    }
                    XCTAssertEqual(CompactIsland.leading(i),
                                   .agentLamp(attention: true, working: false),
                                   "playing=\(playing) meeting=\(meeting) enabled=\(enabled)")
                }
            }
        }
    }

    // MARK: - Leading

    func testTheLampBreathesOnlyWhileSomethingIsWorking() {
        let idle = input { $0.agentsEnabled = true; $0.sessionCount = 1 }
        XCTAssertEqual(CompactIsland.leading(idle), .agentLamp(attention: false, working: false))
        let busy = input { $0.agentsEnabled = true; $0.sessionCount = 1; $0.anyRunning = true }
        XCTAssertEqual(CompactIsland.leading(busy), .agentLamp(attention: false, working: true))
    }

    /// The tick is transient and outranks the lamp, or it would never be seen.
    func testACompletionTickBeatsTheLamp() {
        let i = input { $0.agentsEnabled = true; $0.sessionCount = 1; $0.completionTick = true }
        XCTAssertEqual(CompactIsland.leading(i), .completionTick)
    }

    /// Agents off and nothing waiting: the island belongs to everything else.
    func testWithAgentsOffTheLeadingSlotGoesToMedia() {
        let i = input { $0.agentsEnabled = false; $0.sessionCount = 3; $0.hasMedia = true }
        XCTAssertEqual(CompactIsland.leading(i), .artwork,
                       "sessions exist, but this Mac has said it does not show them")
        XCTAssertEqual(CompactIsland.trailing(i), .empty,
                       "and the sessions leave no trace on the other side either")
    }

    /// A gate overrides the switch — hiding it would leave the agent blocked
    /// until ask_timeout, and switching a widget off is a statement about
    /// clutter rather than consent to hang.
    func testAGateOverridesTheAgentsSwitch() {
        let i = input { $0.agentsEnabled = false; $0.attentionCount = 1; $0.sessionCount = 1 }
        XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: true, working: false))
    }

    func testAnEmptyIslandIsEmpty() {
        XCTAssertEqual(CompactIsland.leading(CompactIslandInput(now: Self.anchor)), .idle,
                       "the bottom rung is the resting island, not nothing")
        XCTAssertEqual(CompactIsland.trailing(CompactIslandInput(now: Self.anchor)), .empty)
    }

    // MARK: - Trailing

    /// Fifteen minutes around a meeting — `CalendarWidgetModel.glanceEvent` runs
    /// from ten minutes before the start to five after it. Music is playing all
    /// afternoon, so the countdown gets the slot while it exists.
    func testAMeetingOutranksMusic() {
        let i = input { $0.mediaPlaying = true; $0.hasMedia = true; $0.meetingSoon = true }
        XCTAssertEqual(CompactIsland.trailing(i), .meetingCountdown)
    }

    func testAttentionOutranksAMeeting() {
        let i = input {
            $0.agentsEnabled = true; $0.attentionCount = 1; $0.sessionCount = 1
            $0.meetingSoon = true
        }
        XCTAssertEqual(CompactIsland.trailing(i), .attentionDot)
    }

    /// Paused, not playing: artwork on the left says which track, and the wave
    /// would be a lie about what the speakers are doing.
    func testPausedMusicGetsNoWave() {
        let i = input { $0.hasMedia = true; $0.mediaPlaying = false }
        XCTAssertEqual(CompactIsland.trailing(i), .empty)
        XCTAssertEqual(CompactIsland.leading(i), .artwork)
    }

    /// **The closed island no longer counts sessions — the owner's decision,
    /// 2026-09-30.** With agents on and sessions open, the lamp opposite already
    /// says agents are there, and how many is the Agents tab's badge in the open
    /// island. This is exactly the input the removed rung used to claim, with
    /// nothing else wanting the slot: it stays empty, or goes to the shelf.
    func testOpenSessionsPutNoNumberOnTheTrailingSide() {
        for sessions in [1, 2, 4] {
            for working in [false, true] {
                let i = input {
                    $0.agentsEnabled = true; $0.sessionCount = sessions; $0.anyRunning = working
                }
                let name = "\(sessions) sessions, working=\(working)"
                XCTAssertEqual(CompactIsland.leading(i),
                               .agentLamp(attention: false, working: working), name)
                XCTAssertEqual(CompactIsland.trailing(i), .empty, name)

                var shelved = i
                shelved.shelfCount = 3
                XCTAssertEqual(CompactIsland.trailing(shelved), .shelfCount(3),
                               "\(name): the shelf gets the place the count held")
            }
        }
    }

    /// A gate with sessions open and no music: the dot, on the side the count
    /// used to fill, and amber on the lamp opposite — attention is worth both
    /// halves, see `testAttentionTakesBothHalvesAndDisplacesMusic`.
    func testAGateWithOpenSessionsShowsTheDot() {
        let i = input { $0.agentsEnabled = true; $0.attentionCount = 1; $0.sessionCount = 2 }
        XCTAssertEqual(CompactIsland.trailing(i), .attentionDot)
        XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: true, working: false))
    }

    // MARK: - The route acknowledgement (transient, ~2s)

    /// The whole point of a caller-supplied `now`: every timing case is one
    /// value, no sleeping, no clock.
    func testTheRouteAckLastsExactlyItsWindow() {
        let t = Self.anchor
        func trailing(after seconds: TimeInterval) -> CompactSlot {
            CompactIsland.trailing(input {
                $0.now = t.addingTimeInterval(seconds); $0.outputChangedAt = t
                $0.outputDeviceName = "AirPods Pro"; $0.outputLevel = 0.4
                $0.outputTransport = .bluetooth
            })
        }
        let lit = CompactSlot.outputRoute(name: "AirPods Pro", transport: .bluetooth,
                                          level: 0.4, muted: false)
        XCTAssertEqual(trailing(after: 0), lit)
        XCTAssertEqual(trailing(after: 1.9), lit)
        XCTAssertEqual(trailing(after: CompactIsland.routeAcknowledgement), .empty,
                       "the boundary is exclusive — 2s in, it is over")
        XCTAssertEqual(trailing(after: 2.1), .empty)
    }

    /// A wall clock that steps backwards (sleep/wake, an NTP correction) must
    /// not light the acknowledgement forever. A 2s glyph that becomes a permanent
    /// one is the exact failure this cluster exists to avoid.
    func testAClockSteppedBackwardsDoesNotStrandTheAck() {
        let t = Self.anchor
        let i = input {
            $0.now = t.addingTimeInterval(-5); $0.outputChangedAt = t
            $0.outputDeviceName = "Studio Display"
        }
        XCTAssertFalse(i.acknowledgingRoute)
        XCTAssertEqual(CompactIsland.trailing(i), .empty)
    }

    /// A two-second signal that yields to a permanent one is never seen, so
    /// ranking it below the steady states would be the same as not building it.
    func testTheRouteAckOutranksEverySteadyState() {
        let t = Self.anchor
        let i = input {
            $0.now = t; $0.outputChangedAt = t; $0.outputDeviceName = "Speakers"
            $0.outputLevel = 0.7; $0.outputTransport = .builtIn
            $0.meetingSoon = true; $0.batteryCritical = true
            $0.hasMedia = true; $0.mediaPlaying = true
            $0.agentsEnabled = true; $0.sessionCount = 2; $0.shelfCount = 3
        }
        XCTAssertEqual(CompactIsland.trailing(i),
                       .outputRoute(name: "Speakers", transport: .builtIn,
                                    level: 0.7, muted: false))
    }

    /// ...but not the gate. A gate has no other surface; the person who just
    /// changed the route pressed a control and can see the result in the panel.
    func testAGateStillOutranksTheRouteAck() {
        let t = Self.anchor
        let i = input {
            $0.now = t; $0.outputChangedAt = t; $0.outputDeviceName = "Speakers"
            $0.agentsEnabled = true; $0.attentionCount = 1; $0.sessionCount = 1
        }
        XCTAssertEqual(CompactIsland.trailing(i), .attentionDot)
    }

    /// A device with no software volume (HDMI, many DACs) and a muted one both
    /// have to survive the trip; the view draws a bar, and "0%" is not a thing
    /// mute means.
    func testTheAckCarriesWhateverTheDeviceCanSayAboutLevel() {
        let t = Self.anchor
        let noLevel = CompactIsland.trailing(input {
            $0.now = t; $0.outputChangedAt = t; $0.outputDeviceName = "LG UltraFine"
            $0.outputTransport = .displayPort
        })
        XCTAssertEqual(noLevel, .outputRoute(name: "LG UltraFine", transport: .displayPort,
                                             level: nil, muted: false))
        let muted = CompactIsland.trailing(input {
            $0.now = t; $0.outputChangedAt = t; $0.outputDeviceName = "Speakers"
            $0.outputLevel = 0.3; $0.outputMuted = true; $0.outputTransport = .builtIn
        })
        XCTAssertEqual(muted, .outputRoute(name: "Speakers", transport: .builtIn,
                                           level: 0.3, muted: true))
    }

    // MARK: - A long-paused track retires from the island

    func testAPausedTrackKeepsItsSlotUntilTheWindowElapses() {
        let t = Self.anchor
        func leading(pausedAgo: TimeInterval) -> CompactSlot {
            CompactIsland.leading(input {
                $0.now = t; $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-pausedAgo)
            })
        }
        XCTAssertEqual(leading(pausedAgo: 0), .artwork)
        XCTAssertEqual(leading(pausedAgo: CompactIsland.mediaRetirement - 1), .artwork,
                       "14:59 — still yours")
        XCTAssertEqual(leading(pausedAgo: CompactIsland.mediaRetirement), .idle,
                       "15:00 — the slot has better uses")
        XCTAssertEqual(leading(pausedAgo: 3600), .idle,
                       "paused an hour ago is the case the whole rule is for")
    }

    /// THE requirement, as one assertion: retirement is about a 16pt slot, not
    /// about forgetting what is loaded. The expanded card reads `hasMedia`.
    func testRetirementNeverClearsTheLoadedTrack() {
        let t = Self.anchor
        let i = input {
            $0.now = t; $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-7200)
        }
        XCTAssertTrue(i.mediaRetired)
        XCTAssertTrue(i.hasMedia, "the card must still have something to show")
        XCTAssertFalse(i.showsMedia)
    }

    /// Pressing play clears the stamp and un-retires the track immediately.
    /// That is why retiring early is cheap and retiring late is not.
    ///
    /// **Playing music no longer takes the leading slot** (2026-08-24). It has a
    /// home opposite — the wave — so it does not need this one, and taking it
    /// meant the Airlock mark vanished for as long as anything was playing. For
    /// a user who declined agents that was most of their day, and the mark was
    /// the only one they ever got. A PAUSED track still takes this side, because
    /// the wave requires `mediaPlaying` and it would otherwise be invisible.
    func testResumingUnretiresImmediately() {
        let t = Self.anchor
        let i = input {
            $0.now = t; $0.hasMedia = true; $0.mediaPlaying = true; $0.mediaPausedAt = nil
        }
        XCTAssertFalse(i.mediaRetired, "play clears the stamp")
        XCTAssertEqual(CompactIsland.leading(i), .idle, "the mark keeps its side")
        XCTAssertEqual(CompactIsland.trailing(i), .wave, "and the music is still said")
    }

    /// Touching the player is intent: a different paused track carries a fresh
    /// stamp, so it gets the slot again rather than inheriting the old one's age.
    func testASwappedPausedTrackGetsTheSlotBack() {
        let t = Self.anchor
        let stale = input {
            $0.now = t; $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-3600)
        }
        XCTAssertEqual(CompactIsland.leading(stale), .idle)
        let swapped = input {
            $0.now = t; $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-2)
        }
        XCTAssertEqual(CompactIsland.leading(swapped), .artwork)
    }

    /// A retired track vacates the leading slot — and the slot now goes back to
    /// the mark rather than to the meeting.
    ///
    /// The meeting is not lost: `trailing` gives it a COUNTDOWN in minutes,
    /// which was always the better of the two representations, and the calendar
    /// glyph here was the redundant one. It reclaims this side in exactly one
    /// case — when a critical battery has taken the trailing slot and the
    /// meeting would otherwise have nowhere to be. See
    /// `testAMeetingKeepsTheLeadingSlotUnderACriticalBattery`, whose rule
    /// ("losing both at once would be a worse trade") is what that exception
    /// preserves.
    func testARetiredTrackVacatesTheSlotBackToTheMark() {
        let t = Self.anchor
        let i = input {
            $0.now = t; $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-3600)
            $0.meetingSoon = true
        }
        XCTAssertEqual(CompactIsland.leading(i), .idle)
        XCTAssertEqual(CompactIsland.trailing(i), .meetingCountdown,
                       "the meeting is said better opposite than it was here")
    }

    // MARK: - A critical battery

    /// **This assertion is the inverse of the one that stood here, and the
    /// reversal was deliberate — read this before restoring the old order.**
    ///
    /// The meeting used to win, on the argument that macOS already interrupts
    /// for a dying battery with its own alert and never for a meeting, so the
    /// island should carry the signal it is the only source of. The argument was
    /// fine; its arithmetic was not. `CalendarWidgetModel.glanceEvent` runs from
    /// ten minutes before an event to five after — fifteen minutes, not ten —
    /// and it re-arms per event, so back-to-back half-hourly meetings keep the
    /// countdown lit fifteen minutes in every thirty. A critical battery's whole
    /// life is fifteen to twenty-five minutes, so on a busy calendar the battery
    /// rung was not delayed, it was unreachable: it could never render once.
    ///
    /// The cost of flipping it, stated so nobody has to rediscover it: for the
    /// fifteen to twenty-five minutes before the machine stops, the countdown is
    /// suppressed. That is accepted because a Mac that dies misses the meeting
    /// anyway, and because the meeting still holds the leading slot as
    /// `.meetingIcon` — see `testAMeetingKeepsTheLeadingSlotUnderACriticalBattery`.
    func testACriticalBatteryOutranksAMeeting() {
        let i = input { $0.meetingSoon = true; $0.batteryCritical = true; $0.batteryMinutesRemaining = 18 }
        XCTAssertEqual(CompactIsland.trailing(i), .batteryCritical(minutes: 18))
    }

    /// The reversal is a TRAILING decision only. Nothing about a battery belongs
    /// to the leading ladder, so the fact of the meeting survives even while its
    /// countdown is suppressed — losing both at once would be a different, worse
    /// trade than the one that was made.
    func testAMeetingKeepsTheLeadingSlotUnderACriticalBattery() {
        let i = input { $0.meetingSoon = true; $0.batteryCritical = true; $0.batteryMinutesRemaining = 18 }
        XCTAssertEqual(CompactIsland.leading(i), .meetingIcon)
    }

    /// Twenty minutes against a whole afternoon, and one of them means the
    /// machine is about to stop.
    func testACriticalBatteryOutranksMusic() {
        let i = input {
            $0.hasMedia = true; $0.mediaPlaying = true
            $0.batteryCritical = true; $0.batteryMinutesRemaining = 18
        }
        XCTAssertEqual(CompactIsland.trailing(i), .batteryCritical(minutes: 18))
    }

    /// Only CRITICAL is admitted. A 20% battery is a 45-90 minute state: above
    /// the wave it costs the wave most of an afternoon (the permanent clutter
    /// the item forbids), below it it is invisible whenever anything is playing,
    /// and an indicator whose absence means nothing is worse than none. `isLow`
    /// keeps its home in the gutter and the expanded card — it is not an input
    /// here at all, and this test is the record of that.
    func testOnlyACriticalBatteryClaimsASlot() {
        let i = input { $0.batteryCritical = false; $0.batteryMinutesRemaining = 70 }
        XCTAssertEqual(CompactIsland.trailing(i), .empty)
    }

    /// IOKit does not always have an estimate — right after waking, or while it
    /// recalibrates. The slot still has something true to say.
    func testACriticalBatteryWithNoEstimateStillShows() {
        let i = input { $0.batteryCritical = true; $0.batteryMinutesRemaining = nil }
        XCTAssertEqual(CompactIsland.trailing(i), .batteryCritical(minutes: nil))
    }

    // MARK: - The keep-awake cup, one rung above the shelf

    /// Everything the ladder ranks above the cup takes the slot from it, and
    /// each claimant is checked for the slot it actually wins with — "not the
    /// cup" alone would pass for a ladder that fell through to `.empty`.
    func testKeepAwakeYieldsToEverythingAboveIt() {
        let t = Self.anchor
        for (name, above, winner) in [
            ("attention", { (i: inout CompactIslandInput) in i.agentsEnabled = true; i.attentionCount = 1 },
             CompactSlot.attentionDot),
            ("route ack", { i in i.now = t; i.outputChangedAt = t; i.outputTransport = .bluetooth },
             .outputRoute(name: nil, transport: .bluetooth, level: nil, muted: false)),
            ("battery", { i in i.batteryCritical = true; i.batteryMinutesRemaining = 12 },
             .batteryCritical(minutes: 12)),
            ("meeting", { i in i.meetingSoon = true }, .meetingCountdown),
            ("wave", { i in i.hasMedia = true; i.mediaPlaying = true }, .wave),
        ] as [(String, (inout CompactIslandInput) -> Void, CompactSlot)] {
            let i = input { $0.keepingAwake = true; above(&$0) }
            XCTAssertEqual(CompactIsland.trailing(i), winner, "\(name) should have won")
        }
    }

    /// The one rung it outranks. Forgetting the cup has a cost and macOS keeps
    /// it out of the menu bar; forgetting a file on the shelf costs nothing
    /// until it is wanted. The shelf gets the slot back the moment the
    /// assertion goes.
    func testKeepAwakeOutranksTheShelfCount() {
        XCTAssertEqual(CompactIsland.trailing(input { $0.keepingAwake = true; $0.shelfCount = 3 }),
                       .keepingAwake)
        XCTAssertEqual(CompactIsland.trailing(input { $0.keepingAwake = false; $0.shelfCount = 3 }),
                       .shelfCount(3))
    }

    func testKeepAwakeTakesTheSlotWhenNobodyElseWants() {
        XCTAssertEqual(CompactIsland.trailing(input { $0.keepingAwake = true }), .keepingAwake)
        XCTAssertEqual(CompactIsland.trailing(input { $0.keepingAwake = false }), .empty)
    }

    /// **Open sessions no longer keep the cup waiting.** Until 2026-09-30 the
    /// session count sat one rung above it, so with agents on the cup showed
    /// only once the last session ended — rarely, for anyone who uses agents.
    /// The count has left the closed island: the lamp opposite still says agents
    /// are there, idle or working, and this side goes to the cup. Switched off,
    /// sessions reach neither side, as before.
    func testTheCupWinsOverOpenSessions() {
        for enabled in [true, false] {
            for sessions in [1, 2, 5] {
                for working in [false, true] {
                    let i = input {
                        $0.agentsEnabled = enabled; $0.sessionCount = sessions
                        $0.anyRunning = working; $0.keepingAwake = true
                    }
                    let name = "agents \(enabled ? "on" : "off"), \(sessions) sessions, working=\(working)"
                    XCTAssertEqual(CompactIsland.trailing(i), .keepingAwake, name)
                    XCTAssertEqual(CompactIsland.leading(i),
                                   enabled ? CompactSlot.agentLamp(attention: false, working: working)
                                           : .idle,
                                   name)
                }
            }
        }
    }

    /// ...as long as nothing above it wants the slot. Music playing still
    /// outranks the cup with sessions open; the decision moved the count, not
    /// the wave.
    func testTheWaveStillOutranksTheCupWithSessionsOpen() {
        let i = input {
            $0.agentsEnabled = true; $0.sessionCount = 2; $0.anyRunning = true
            $0.keepingAwake = true; $0.hasMedia = true; $0.mediaPlaying = true
        }
        XCTAssertEqual(CompactIsland.trailing(i), .wave)
        XCTAssertEqual(CompactIsland.leading(i), .agentLamp(attention: false, working: true))
    }

    /// Trailing only. The leading side belongs to the mark, and a cup there
    /// would be a second place saying the same thing.
    func testKeepAwakeNeverReachesTheLeadingSide() {
        XCTAssertEqual(CompactIsland.leading(input { $0.keepingAwake = true }), .idle)
    }

    // MARK: - The shelf count, last in line

    func testTheShelfCountYieldsToEverything() {
        let t = Self.anchor
        for (name, above) in [
            ("attention", { (i: inout CompactIslandInput) in i.agentsEnabled = true; i.attentionCount = 1 }),
            ("route ack", { i in i.now = t; i.outputChangedAt = t }),
            ("meeting", { i in i.meetingSoon = true }),
            ("battery", { i in i.batteryCritical = true }),
            ("wave", { i in i.hasMedia = true; i.mediaPlaying = true }),
            ("keep-awake", { i in i.keepingAwake = true }),
        ] as [(String, (inout CompactIslandInput) -> Void)] {
            let i = input { $0.shelfCount = 3; above(&$0) }
            XCTAssertNotEqual(CompactIsland.trailing(i), .shelfCount(3), "\(name) should have won")
        }
    }

    func testTheShelfCountTakesTheSlotWhenNobodyElseWants() {
        XCTAssertEqual(CompactIsland.trailing(input { $0.shelfCount = 3 }), .shelfCount(3))
        XCTAssertEqual(CompactIsland.trailing(input { $0.shelfCount = 0 }), .empty)
    }

    // MARK: - The two halves never say the same thing

    /// The slots never draw the IDENTICAL thing. Attention is the deliberate
    /// near-exception: it shows on both, but as a lamp and a dot, not twice.
    ///
    /// A sweep over an explicit domain rather than the ten nested `for`s this
    /// would otherwise have become: each axis names its own variants, so adding
    /// an eleventh claimant is one array entry and the failure message says
    /// which combination broke.
    func testTheTwoSlotsNeverShowTheSameThing() {
        sweep { name, i in
            let (l, t) = (CompactIsland.leading(i), CompactIsland.trailing(i))
            if l != .empty { XCTAssertNotEqual(l, t, "duplicated for \(name)") }
        }
    }

    /// The 2026-09-30 decision as a property of the whole ladder rather than of
    /// one enum case: the trailing side is blind to how many sessions are open.
    /// Every combination resolves to the same slot with its sessions taken away
    /// — gates left in, so it is the COUNT being checked, not attention. A rung
    /// that brings the number back, under any name, fails here.
    func testTheTrailingSideIsBlindToTheNumberOfSessions() {
        sweep { name, i in
            var none = i
            none.sessionCount = 0
            XCTAssertEqual(CompactIsland.trailing(i), CompactIsland.trailing(none), name)
        }
    }

    // MARK: - The sweep

    typealias Variant = (name: String, apply: (inout CompactIslandInput) -> Void)

    /// One instant for the whole sweep, so "recently" and "ages ago" are exact.
    static let anchor = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every axis the ladder resolves against, one small set of variants each.
    /// A property rather than a `static let` because a closure is not `Sendable`
    /// and Swift 6 will not have a shared global of them.
    var axes: [[Variant]] {
        let t = Self.anchor
        return [
            [("agents off", { $0.agentsEnabled = false }),
             ("agents on", { $0.agentsEnabled = true })],
            [("no gate", { $0.attentionCount = 0 }),
             ("gate", { $0.attentionCount = 1; $0.sessionCount = max($0.sessionCount, 1) })],
            // No trailing rung reads this any more (2026-09-30); it stays an
            // axis because it is what lights the leading lamp, and the lamp is
            // half of what the two-slot check compares.
            [("no session", { $0.sessionCount = max($0.sessionCount, 0) }),
             ("2 sessions", { $0.sessionCount = max($0.sessionCount, 2) })],
            [("no tick", { $0.completionTick = false }),
             ("tick", { $0.completionTick = true })],
            [("no media", { _ in }),
             ("playing", { $0.hasMedia = true; $0.mediaPlaying = true }),
             ("paused", { $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-60) }),
             ("retired", { $0.hasMedia = true; $0.mediaPausedAt = t.addingTimeInterval(-3600) })],
            [("no meeting", { _ in }), ("meeting", { $0.meetingSoon = true })],
            [("no route", { _ in }),
             ("route ack", { $0.outputChangedAt = t.addingTimeInterval(-1); $0.outputDeviceName = "AirPods" })],
            [("battery ok", { _ in }),
             ("battery critical", { $0.batteryCritical = true; $0.batteryMinutesRemaining = 12 })],
            [("empty shelf", { _ in }), ("3 on shelf", { $0.shelfCount = 3 })],
            [("sleeps normally", { _ in }), ("kept awake", { $0.keepingAwake = true })],
        ]
    }

    /// The cartesian product of the axes, each case carrying the names that
    /// produced it. 2,048 combinations, instant, and readable at the failure.
    func sweep(_ body: (String, CompactIslandInput) -> Void) {
        func walk(_ remaining: ArraySlice<[Variant]>, _ name: String, _ i: CompactIslandInput) {
            guard let axis = remaining.first else { return body(name, i) }
            for variant in axis {
                var next = i
                variant.apply(&next)
                walk(remaining.dropFirst(), name.isEmpty ? variant.name : "\(name), \(variant.name)", next)
            }
        }
        walk(axes[...], "", CompactIslandInput(now: Self.anchor))
    }
}

/// The guide's rung in both halves of the island.
final class CompactIslandGuideTests: XCTestCase {
    private let guiding = GuidePresentation.Compact.guiding(step: 2, of: 5, offTrack: false)

    func testAGateOutranksTheGuide() {
        let i = CompactIslandInput(agentsEnabled: true, attentionCount: 1, sessionCount: 1, now: Date(), guide: guiding)
        XCTAssertEqual(CompactIsland.trailing(i), .attentionDot)
    }

    func testTheGuideOutranksEverythingAmbientAndSummonsTheIsland() {
        let i = CompactIslandInput(hasMedia: true, mediaPlaying: true, meetingSoon: true, now: Date(),
                                   batteryCritical: true, batteryMinutesRemaining: 5, shelfCount: 3, guide: guiding)
        XCTAssertEqual(CompactIsland.trailing(i), .guide(guiding))
        XCTAssertTrue(CompactIsland.hasContent(CompactIslandInput(now: Date(), guide: guiding)))
    }

    func testTheGuidePutsTheMarkBackOnTheLeft() {
        let paused = CompactIslandInput(hasMedia: true, now: Date(), mediaPausedAt: Date(), guide: guiding)
        XCTAssertEqual(CompactIsland.leading(paused), .idle)
    }
}
