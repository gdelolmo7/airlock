import XCTest
@testable import AirlockCore

/// The catalog in Spanish, end to end through the real grammar.
///
/// One file rather than a case per action file, because the property under
/// test is shared: a language is words on the triggers and rows in the shared
/// lists, never a second grammar — so what this file proves is that the
/// EXISTING machinery resolves Spanish phrasing, not that new machinery does.
final class VoiceSpanishTests: XCTestCase {

    private var context: VoiceContext {
        VoiceContext(
            audioOutputs: [AudioOutputDevice(uid: "u1", name: "AirPods Pro"),
                           AudioOutputDevice(uid: "u2", name: "MacBook Pro Speakers")],
            shortcuts: ["Enfoque"],
            apps: [VoiceAppTarget(path: "/Applications/Claude.app", name: "Claude"),
                   VoiceAppTarget(path: "/Applications/Spotify.app", name: "Spotify"),
                   VoiceAppTarget(path: "/Applications/1Password.app", name: "1Password"),
                   // The alias the scan reads from the bundle's own es.lproj —
                   // the on-disk name stays English on an English system.
                   VoiceAppTarget(path: "/System/Applications/Music.app", name: "Music",
                                  aliases: ["Música"]),
                   VoiceAppTarget(path: "/System/Applications/Calendar.app", name: "Calendar",
                                  aliases: ["Calendario"])],
            sites: VoiceSiteAliases.merged(user: [
                VoiceSiteAlias(phrase: "calendario",
                               url: "https://calendar.google.com"),
            ]),
            volume: 0.5)
    }

    private func propose(_ spoken: String) -> ActionProposal? {
        let offering = VoiceActionCatalog.offered(shortcuts: true)
        for candidate in VoiceGrammar.candidates(spoken, offering: offering) {
            if let proposal = VoiceActionCatalog.propose(actionNamed: candidate.name,
                                                         arguments: candidate.arguments,
                                                         in: context, offering: offering) {
                return proposal
            }
        }
        return nil
    }

    // MARK: - Routing

    func testPonElSonidoEnLosAirpods() throws {
        let proposal = try XCTUnwrap(propose("pon el sonido en los airpods"))
        XCTAssertEqual(proposal.toolName, "Voice.AudioOutput")
        XCTAssertEqual(proposal.subject, "AirPods Pro")
    }

    // MARK: - Transport
    //
    // "pon la musica" is play and "pon la musica en la tele" is routing — the
    // same split English has with "play", resolved the same way: the audio
    // trigger needs a preposition after its object, and registry order does
    // the rest.

    func testPausaLaMusica() throws {
        XCTAssertEqual(try XCTUnwrap(propose("pausa la musica")).effect, .media(.pause))
    }

    func testPonLaMusica() throws {
        XCTAssertEqual(try XCTUnwrap(propose("pon la musica")).effect, .media(.play))
    }

    func testSiguienteCancion() throws {
        XCTAssertEqual(try XCTUnwrap(propose("siguiente cancion")).effect, .media(.next))
    }

    // MARK: - Volume

    func testSubeElVolumen() throws {
        // The direction lives in the verb, with nothing after the object —
        // the shape the `theVerb` trigger exists for. From 50%, one step up.
        XCTAssertEqual(try XCTUnwrap(propose("sube el volumen")).effect, .setVolume(0.6))
    }

    func testBajaElVolumen() throws {
        XCTAssertEqual(try XCTUnwrap(propose("baja el volumen")).effect, .setVolume(0.4))
    }

    func testPonElVolumenAl50() throws {
        XCTAssertEqual(try XCTUnwrap(propose("pon el volumen al 50")).effect, .setVolume(0.5))
    }

    /// A destination beats a direction when the phrase names both: the
    /// absolute trigger is registered first, so "a tope" wins over "sube".
    func testSubeElVolumenATope() throws {
        XCTAssertEqual(try XCTUnwrap(propose("sube el volumen a tope")).effect, .setVolume(1.0))
    }

    // MARK: - Agent and Shortcuts

    func testDileAClaudeQueCorraLosTests() throws {
        let proposal = try XCTUnwrap(propose("dile a claude que corra los tests"))
        XCTAssertEqual(proposal.toolName, "Voice.Agent")
        XCTAssertTrue(proposal.summary.contains("corra los tests"),
                      "the prompt should survive intact: \(proposal.summary)")
    }

    func testEjecutaElAtajoLlamadoEnfoque() throws {
        let proposal = try XCTUnwrap(propose("ejecuta el atajo llamado enfoque"))
        XCTAssertEqual(proposal.toolName, "Voice.Shortcut")
        XCTAssertEqual(proposal.subject, "Enfoque")
    }

    // MARK: - Localized app names

    /// The gap the last commit recorded, now closed: the app is named Music
    /// on disk whatever language is spoken at it, and the alias is what "la
    /// música" can reach. Folding strips the accent on both sides.
    func testAbreLaMusica() throws {
        let proposal = try XCTUnwrap(propose("abre la musica"))
        XCTAssertEqual(proposal.toolName, "Voice.Open")
        XCTAssertEqual(proposal.subject, "Music")
    }

    /// And the alias does not shadow the real name: both spellings reach the
    /// same app, so neither language gets a different Mac.
    func testOpenTheMusicStillWorks() throws {
        XCTAssertEqual(try XCTUnwrap(propose("open the music")).subject, "Music")
    }

    // MARK: - Ordinals

    func testSpanishOrdinals() {
        XCTAssertEqual(VoiceMatch.ordinal("la segunda cosa"), 2)
        XCTAssertEqual(VoiceMatch.ordinal("tercer enlace"), 3)
        XCTAssertNil(VoiceMatch.ordinal("la ultima cosa"),
                     "\"ultimo\" is excluded for the reason \"last\" is")
    }

    // MARK: - Refusals
    //
    // The safety half must hold in Spanish too: questions are answered, not
    // executed. The you-form request stays admitted, exactly like "can you".

    func testComoSuboElVolumenIsAQuestion() {
        XCTAssertNil(propose("como subo el volumen"))
    }

    func testPuedoAbrirSpotifyIsAQuestion() {
        XCTAssertNil(propose("puedo abrir spotify"))
    }

    func testPuedesAbrirSpotifyIsARequest() throws {
        XCTAssertEqual(try XCTUnwrap(propose("puedes abrir spotify")).subject, "Spotify")
    }

    /// The screenshot that earned it, verbatim: the transcription was right,
    /// "puedes" passed the polite-request gate, and the match still missed —
    /// because the app spells itself with a digit nobody can say. It must
    /// propose the app, never fall through to the model.
    func testPuedesAbrirOnePassword() throws {
        XCTAssertEqual(try XCTUnwrap(propose("puedes abrir one password")).subject,
                       "1Password")
    }

    // MARK: - Show verbs and the browser qualifier
    //
    // The second screenshot, verbatim: "Vale, enséñame el calendario en
    // Chrome" fell through to the Q&A model, which invented chrome://calendar/
    // with five confident steps. Two gaps: no show-verbs, and no reading for
    // a trailing "en <browser>".

    /// With a page taught for "calendario", the qualifier picks it — naming
    /// a browser is asking for a page, so sites outrank apps under it.
    func testEnsenameElCalendarioEnChrome() throws {
        let proposal = try XCTUnwrap(propose("vale ensename el calendario en chrome"))
        XCTAssertEqual(proposal.toolName, "Voice.Open")
        XCTAssertEqual(proposal.effect,
                       .open(target: .url("https://calendar.google.com")))
    }

    /// Without the qualifier the plain order holds: apps first, so the same
    /// word opens Calendar.app through its localized alias.
    func testEnsenameElCalendario() throws {
        XCTAssertEqual(try XCTUnwrap(propose("ensename el calendario")).subject,
                       "Calendar")
    }

    func testShowMeTheCalendar() throws {
        XCTAssertEqual(try XCTUnwrap(propose("show me the calendar")).subject,
                       "Calendar")
    }

    /// "in" followed by something that is not a browser is part of the name,
    /// not a qualifier — the phrase resolves exactly as it always did.
    func testInSomethingThatIsNotABrowserIsUntouched() throws {
        XCTAssertEqual(try XCTUnwrap(propose("abre spotify en la oficina")).subject,
                       "Spotify")
    }
}
