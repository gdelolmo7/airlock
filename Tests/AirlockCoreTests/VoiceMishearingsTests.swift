import XCTest
@testable import AirlockCore

/// The spelling gap between what was said and what the recogniser wrote.
///
/// Every case here is a transcript that actually happened: "go to Claude Code"
/// arriving as "cloud code", "clot code", "cloudy code" is the report that
/// created the file. The variants are guesses, so the properties under test
/// are about restraint as much as reach — the original query is never a
/// variant of itself, and a sentence is never crushed into one unmatchable
/// token.
final class VoiceMishearingsTests: XCTestCase {

    // MARK: - The report's own transcripts

    func testCloudCodeBecomesClaudeCode() {
        XCTAssertTrue(VoiceMishearings.variants(of: "cloud code").contains("claude code"))
    }

    func testClotCodeBecomesClaudeCode() {
        XCTAssertTrue(VoiceMishearings.variants(of: "clot code").contains("claude code"))
    }

    func testCloudyCodeBecomesClaudeCode() {
        XCTAssertTrue(VoiceMishearings.variants(of: "cloudy code").contains("claude code"))
    }

    func testBareCloudBecomesClaude() {
        XCTAssertTrue(VoiceMishearings.variants(of: "cloud").contains("claude"))
    }

    func testCodecsBecomesCodex() {
        XCTAssertTrue(VoiceMishearings.variants(of: "codecs").contains("codex"))
    }

    // MARK: - Nicknames and splits

    func testVSCodeMeansVisualStudioCode() {
        XCTAssertTrue(VoiceMishearings.variants(of: "vs code")
            .contains("visual studio code"))
    }

    func testSplitCompoundJoins() {
        // The generic lens, no table entry required: a two-word query is also
        // tried as one word, which is how "chat gpt" reaches an app whose
        // bundle spells itself "ChatGPT".
        XCTAssertTrue(VoiceMishearings.variants(of: "chat gpt").contains("chatgpt"))
        XCTAssertTrue(VoiceMishearings.variants(of: "x code").contains("xcode"))
    }

    func testSpokenNumbersReachDigitNames() {
        // "1Password" is spoken "one password" — the number table and the
        // join lens compose into the exact on-disk spelling. The live failure
        // that earned it: "puedes abrir one password" answered by the model
        // instead of opened.
        XCTAssertTrue(VoiceMishearings.variants(of: "one password").contains("1password"))
        XCTAssertTrue(VoiceMishearings.variants(of: "uno password").contains("1password"))
    }

    // MARK: - Restraint

    func testTheOriginalIsNeverAVariant() {
        XCTAssertFalse(VoiceMishearings.variants(of: "cloud code").contains("cloud code"))
        // A query the tables know nothing about produces nothing — the caller
        // has already tried the only spelling there is.
        XCTAssertFalse(VoiceMishearings.variants(of: "spotify").contains("spotify"))
    }

    func testASentenceIsNotCrushedIntoOneToken() {
        // Joining is for two- and three-word names. A longer capture is a
        // sentence, and a sentence glued together matches nothing on purpose.
        XCTAssertFalse(VoiceMishearings.variants(of: "the notes I wrote about clouds")
            .contains { !$0.contains(" ") && $0.count > 20 })
    }

    func testEmptyInMeansEmptyOut() {
        XCTAssertTrue(VoiceMishearings.variants(of: "  ").isEmpty)
    }

    func testVariantsAreFolded() {
        // The tables and the joiner both operate on folded text, so anything
        // returned is already in `VoiceMatch.fold` form and can be handed to
        // `VoiceMatch.matches` unchanged.
        for variant in VoiceMishearings.variants(of: "Open CLOUD Code!") {
            XCTAssertEqual(variant, VoiceMatch.fold(variant))
        }
    }
}
