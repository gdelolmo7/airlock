import XCTest
@testable import AirlockCore

final class MeetingLinksTests: XCTestCase {
    func testDetectsCommonProviders() {
        let cases = [
            "https://zoom.us/j/123456789?pwd=abc",
            "https://us02web.zoom.us/j/987654",
            "https://meet.google.com/abc-defg-hij",
            "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x",
            "https://company.webex.com/meet/guille",
        ]
        for link in cases {
            XCTAssertEqual(
                MeetingLinks.detect(url: nil, location: nil, notes: "Join: \(link) — agenda below")?.url.absoluteString,
                link, "failed for \(link)")
        }
    }

    func testFieldPriorityURLBeatsNotes() {
        let link = MeetingLinks.detect(
            url: "https://meet.google.com/aaa-bbbb-ccc",
            location: nil,
            notes: "old link https://zoom.us/j/1")
        XCTAssertEqual(link?.url.host, "meet.google.com")
        XCTAssertEqual(link?.provider, .googleMeet)
    }

    func testIgnoresNonMeetingURLs() {
        XCTAssertNil(MeetingLinks.detect(
            url: "https://github.com/some/repo",
            location: "Room 4",
            notes: "docs at https://notion.so/page and https://example.com"))
    }

    func testTrailingPunctuationAndProseSurvive() {
        let link = MeetingLinks.detect(url: nil, location: nil,
                                       notes: "Call here: https://zoom.us/j/555777999.")
        XCTAssertEqual(link?.url.absoluteString, "https://zoom.us/j/555777999")
    }

    func testSkipsNonMeetingThenFindsMeeting() {
        let link = MeetingLinks.detect(url: nil, location: nil,
                                       notes: "prep https://docs.google.com/x then https://meet.google.com/xyz-abcd-efg")
        XCTAssertEqual(link?.url.host, "meet.google.com")
    }

    func testEmptyAndNilAreNil() {
        XCTAssertNil(MeetingLinks.detect(url: nil, location: nil, notes: nil))
        XCTAssertNil(MeetingLinks.detect(url: "", location: "", notes: ""))
    }

    // MARK: - Provider identification

    func testProviderIsCarriedThrough() {
        let expected: [(String, MeetingLink.Provider)] = [
            ("https://zoom.us/j/1", .zoom),
            ("https://us02web.zoom.us/j/1", .zoom),
            ("https://meet.google.com/abc-defg-hij", .googleMeet),
            ("https://teams.microsoft.com/l/meetup-join/19%3ax", .teams),
            ("https://teams.live.com/meet/9312345", .teams),
            ("https://company.webex.com/meet/guille", .webex),
            ("https://whereby.com/airlock", .whereby),
            ("https://around.co/r/airlock", .around),
            ("https://meet.jit.si/AirlockStandup", .jitsi),
            ("https://8x8.vc/room-name", .jitsi),
            ("https://bluejeans.com/123456789", .blueJeans),
            ("https://discord.gg/abcdef", .discord),
        ]
        for (link, provider) in expected {
            XCTAssertEqual(MeetingLinks.detect(url: link, location: nil, notes: nil)?.provider,
                           provider, "failed for \(link)")
        }
    }

    func testButtonTitleNamesTheProvider() {
        func title(_ link: String) -> String? {
            MeetingLinks.detect(url: link, location: nil, notes: nil)?.buttonTitle
        }
        XCTAssertEqual(title("https://zoom.us/j/1"), "Join Zoom")
        XCTAssertEqual(title("https://meet.google.com/abc-defg-hij"), "Join Meet")
        XCTAssertEqual(title("https://teams.microsoft.com/l/meetup-join/19%3ax"), "Join Teams")
        XCTAssertEqual(title("https://whereby.com/airlock"), "Join Whereby")
        // No brand to claim, so it claims none.
        XCTAssertEqual(title("https://vc.acme.com/standup"), "Join")
    }

    func testUnknownProviderIsDescribedByItsHost() {
        let link = MeetingLinks.detect(url: "https://vc.acme.com/standup", location: nil, notes: nil)
        XCTAssertEqual(link?.provider, .unknown)
        XCTAssertNil(link?.provider.displayName)
        XCTAssertEqual(link?.joinDescription, "Join the call at vc.acme.com")
    }

    func testKnownProviderDescriptionUsesFullName() {
        let link = MeetingLinks.detect(url: "https://teams.microsoft.com/l/meetup-join/19%3ax",
                                       location: nil, notes: nil)
        XCTAssertEqual(link?.joinDescription, "Join the Microsoft Teams call")
    }

    // MARK: - Unlisted hosts that are still plainly rooms

    func testRoomShapedHostsAreJoinable() {
        let cases = [
            "https://meet.acme.com/standup",       // host label names a room
            "https://vc.example.org/x",
            "https://video.university.edu/lecture",
            "https://conference.acme.io/",
            "https://acme.example/join/abc123",    // path segment names a room
            "https://selfhosted.example/j/9981",
            "https://bbb.acme.com/room/weekly",
        ]
        for link in cases {
            let detected = MeetingLinks.detect(url: nil, location: link, notes: nil)
            XCTAssertEqual(detected?.provider, .unknown, "failed for \(link)")
            XCTAssertEqual(detected?.url.absoluteString, link, "failed for \(link)")
        }
    }

    /// The asymmetry the rule is built on: a false negative costs a copy-paste,
    /// a false positive costs the meeting. These must all stay silent.
    func testNonRoomShapedURLsStaySilent() {
        let cases = [
            "https://example.com",
            "https://example.com/agenda",
            "https://acme.example/join",           // one segment: a marketing page
            "https://docs.google.com/document/d/x",
            "https://notion.so/Weekly-Sync-abc",
            "https://github.com/acme/repo/pull/42",
            "https://maps.apple.com/?ll=41.38,2.17",
            "https://calendar.google.com/event?eid=x",
        ]
        for link in cases {
            XCTAssertNil(MeetingLinks.detect(url: nil, location: nil, notes: "see \(link) before we meet"),
                         "should not have detected \(link)")
        }
    }

    /// A bare link in the notes is not a meeting, but the same link in the
    /// location field is not one either — the shape rule is the only gate, so
    /// which field it came from cannot smuggle anything in.
    func testFieldDoesNotPromoteABareLink() {
        XCTAssertNil(MeetingLinks.detect(url: nil, location: "https://example.com/agenda", notes: nil))
        XCTAssertNil(MeetingLinks.detect(url: "https://example.com/agenda", location: nil, notes: nil))
    }

    // MARK: - A known provider outranks a room-shaped guess, globally

    /// The reported failure: a Slack workspace invite sits earlier in the notes
    /// than the real call, and its leftmost label (`join`) is in the room
    /// vocabulary. Document order would hand it a generic "Join" button.
    func testSlackInviteDoesNotBeatALaterZoomLink() {
        let notes = "Slack: https://join.slack.com/t/acme/shared_invite/xyz "
            + "— call: https://acme.zoom.us/j/8412"
        let link = MeetingLinks.detect(url: nil, location: nil, notes: notes)
        XCTAssertEqual(link?.provider, .zoom)
        XCTAssertEqual(link?.url.absoluteString, "https://acme.zoom.us/j/8412")
        XCTAssertEqual(link?.buttonTitle, "Join Zoom")
    }

    /// Same class, via the host label: `conference.acme.io` is room-shaped and
    /// comes first, but a listed host is a listed host.
    func testRoomShapedHostLabelDoesNotBeatALaterKnownProvider() {
        let notes = "agenda https://conference.acme.io/2026 then https://meet.google.com/abc-defg-hij"
        let link = MeetingLinks.detect(url: nil, location: nil, notes: notes)
        XCTAssertEqual(link?.provider, .googleMeet)
        XCTAssertEqual(link?.url.host, "meet.google.com")
    }

    /// Same class, via the path segment: `…/conference/agenda` is room-shaped.
    func testRoomShapedPathSegmentDoesNotBeatALaterKnownProvider() {
        let notes = "docs https://acme.example/conference/agenda — join https://whereby.com/airlock"
        let link = MeetingLinks.detect(url: nil, location: nil, notes: notes)
        XCTAssertEqual(link?.provider, .whereby)
    }

    /// The pass order beats field priority, not the other way round: a
    /// room-shaped location cannot outrank a listed host in the notes.
    func testKnownProviderInNotesBeatsARoomShapedLocation() {
        let link = MeetingLinks.detect(url: nil,
                                       location: "https://vc.acme.com/standup",
                                       notes: "actually on https://zoom.us/j/4242")
        XCTAssertEqual(link?.provider, .zoom)
        XCTAssertEqual(link?.url.absoluteString, "https://zoom.us/j/4242")
    }

    /// Field priority still decides inside each pass — both of these are known
    /// providers, so the earlier field wins as it always did.
    func testFieldPriorityStillDecidesAmongKnownProviders() {
        let link = MeetingLinks.detect(url: nil,
                                       location: "https://meet.google.com/aaa-bbbb-ccc",
                                       notes: "older https://zoom.us/j/1")
        XCTAssertEqual(link?.provider, .googleMeet)
    }

    /// …and inside the fallback pass too: with no listed host anywhere, the
    /// room-shaped location beats the room-shaped notes link.
    func testFieldPriorityStillDecidesAmongRoomShapedLinks() {
        let link = MeetingLinks.detect(url: nil,
                                       location: "https://vc.acme.com/standup",
                                       notes: "or https://meet.example.org/other")
        XCTAssertEqual(link?.provider, .unknown)
        XCTAssertEqual(link?.url.host, "vc.acme.com")
    }

    /// Demoting the guess must not delete it: a lone room-shaped link is still
    /// the answer when nothing listed appears at all.
    func testRoomShapedLinkStillWinsWhenNoKnownProviderExists() {
        let link = MeetingLinks.detect(url: nil, location: nil,
                                       notes: "notes https://example.com/agenda then https://vc.acme.com/standup")
        XCTAssertEqual(link?.provider, .unknown)
        XCTAssertEqual(link?.url.host, "vc.acme.com")
    }

    // MARK: - App-scheme handoff

    func testZoomHandsOffToTheApp() {
        let link = MeetingLinks.detect(url: "https://us02web.zoom.us/j/987654321?pwd=SeCrEt", location: nil, notes: nil)
        XCTAssertEqual(link?.appURL?.absoluteString,
                       "zoommtg://us02web.zoom.us/join?confno=987654321&pwd=SeCrEt")
    }

    func testZoomWithoutPasswordOmitsIt() {
        let link = MeetingLinks.detect(url: "https://zoom.us/j/12345", location: nil, notes: nil)
        XCTAssertEqual(link?.appURL?.absoluteString, "zoommtg://zoom.us/join?confno=12345")
    }

    /// A personal room resolves server side: there is no meeting number to hand
    /// over, so guessing one would send the app somewhere that does not exist.
    func testZoomPersonalRoomStaysOnHTTPS() {
        let link = MeetingLinks.detect(url: "https://zoom.us/my/guille", location: nil, notes: nil)
        XCTAssertEqual(link?.provider, .zoom)
        XCTAssertNil(link?.appURL)
    }

    func testTeamsHandsOffToTheApp() {
        let raw = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_x%40thread.v2/0?context=%7B%22Tid%22%3A%22t%22%7D"
        let link = MeetingLinks.detect(url: raw, location: nil, notes: nil)
        XCTAssertEqual(link?.appURL?.absoluteString,
                       raw.replacingOccurrences(of: "https://", with: "msteams://"))
    }

    /// `teams.live.com/meet/…` is a Teams meeting but not a `/l/` deep link, so
    /// there is no documented conversion and it stays on https.
    func testTeamsPersonalLinkStaysOnHTTPS() {
        let link = MeetingLinks.detect(url: "https://teams.live.com/meet/9312345", location: nil, notes: nil)
        XCTAssertEqual(link?.provider, .teams)
        XCTAssertNil(link?.appURL)
    }

    /// Everything we have not verified is left alone on purpose — a wrong
    /// scheme fails into the wrong app, which is worse than a browser trip.
    func testUnverifiedProvidersHaveNoAppURL() {
        let cases = [
            "https://meet.google.com/abc-defg-hij",
            "https://company.webex.com/meet/guille",
            "https://whereby.com/airlock",
            "https://around.co/r/airlock",
            "https://meet.jit.si/AirlockStandup",
            "https://bluejeans.com/123456789",
            "https://discord.gg/abcdef",
            "https://vc.acme.com/standup",
        ]
        for link in cases {
            XCTAssertNil(MeetingLinks.detect(url: link, location: nil, notes: nil)?.appURL,
                         "should not have invented a scheme for \(link)")
        }
    }

    // MARK: - Naming the call where there is no room for a button

    /// The all-day chip has room for a glyph and nothing else, so the only
    /// place the call can be named is out loud.
    func testCallSummaryNamesTheProvider() {
        func summary(_ link: String) -> String? {
            MeetingLinks.detect(url: link, location: nil, notes: nil)?.callSummary
        }
        XCTAssertEqual(summary("https://zoom.us/j/1"), "Zoom call")
        XCTAssertEqual(summary("https://meet.google.com/abc-defg-hij"), "Google Meet call")
        XCTAssertEqual(summary("https://teams.microsoft.com/l/meetup-join/19%3ax"),
                       "Microsoft Teams call")
    }

    /// Same rule as `joinDescription`: an unlisted room is named by its host
    /// rather than dressed up as a brand we recognise.
    func testCallSummaryFallsBackToTheHost() {
        let link = MeetingLinks.detect(url: "https://vc.acme.com/standup", location: nil, notes: nil)
        XCTAssertEqual(link?.callSummary, "call at vc.acme.com")
    }

    /// `callSummary` is a noun and `buttonTitle` is an imperative: the chip
    /// reads the first as part of its label and offers the second as a named
    /// action, and swapping them makes VoiceOver say "Offsite, all day, Join".
    func testCallSummaryAndButtonTitleAreNotTheSameString() {
        let link = MeetingLinks.detect(url: "https://zoom.us/j/1", location: nil, notes: nil)
        XCTAssertEqual(link?.buttonTitle, "Join Zoom")
        XCTAssertEqual(link?.callSummary, "Zoom call")
    }

    /// Every provider can name itself in a chip label, including the one that
    /// deliberately has no brand to claim.
    func testEveryProviderHasACallSummary() {
        for provider in MeetingLink.Provider.allCases {
            let link = MeetingLink(provider: provider,
                                   url: URL(string: "https://vc.acme.com/standup")!)
            XCTAssertFalse(link.callSummary.isEmpty, "\(provider) had nothing to say")
            XCTAssertTrue(link.callSummary.hasSuffix("call")
                          || link.callSummary.contains("call at"),
                          "\(provider) did not describe a call: \(link.callSummary)")
        }
    }
}
