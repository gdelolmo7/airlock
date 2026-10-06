import SwiftUI
import AirlockCore

/// Which `Theme` colour the body takes. A role, never a `Color`, so the mapping
/// stays one switch in one place and no call site can invent a hex.
enum BloubTint: Equatable {
    case body, working, attention, done, error, assistant, resting

    var color: Color {
        switch self {
        case .body: return Theme.bloubBody
        case .working: return Theme.running
        case .attention: return Theme.needs
        case .done: return Theme.done
        case .error: return Theme.danger
        case .assistant: return Theme.assistant
        case .resting: return Theme.resting
        }
    }
}

/// How often it blinks, and whether it blinks at all.
///
/// **Rate is the point, not presence.** The island used to blink only while an
/// agent worked, so motion meant something. Making it always-on would spend that
/// channel — a thing that always moves is wallpaper — so resting breathes at
/// less than half the rate of working instead of stopping.
enum BloubMotion: Equatable {
    case still, breathing, working

    /// Seconds between blinks. `working` is the measured source cadence; see
    /// `BloubView.betweenDuration`.
    var interval: Double? {
        switch self {
        case .still: return nil
        case .breathing: return 6.5
        case .working: return BloubView.betweenDuration
        }
    }
}

/// What the character is doing, resolved from what the island is about.
///
/// **The bug this replaces: the face was an agent-status mascot in an app that
/// is not only for agents.** Expression and tint were hand-rolled at the island
/// call site as two ternaries over session state, so a user who never starts an
/// agent — a large and deliberate slice of the audience, with a whole
/// "I don't use coding agents" path in onboarding — only ever saw `.sleepy` in
/// grey, and saw nothing at all whenever music or a meeting took the leading
/// slot. Meanwhile `BloubExpression(for:)` and `Theme.accent(for:)` already
/// resolved four faces and four colours that never reached the island.
///
/// So the source is now the SLOT the ladder already picked, plus the ambient
/// facts it does not carry. Both audiences get a live character: agent states
/// for one, and voice, battery, meetings and the network for everyone.
struct BloubFace: Equatable {
    var expression: BloubExpression
    var tint: BloubTint
    var motion: BloubMotion
    /// The resting rung is drawn down at 0.6. It is not decoration: a solid
    /// tinted cloud at full strength is what made "a notch with nothing
    /// happening in it look busy", and dimming is what fixed it. Intensity is a
    /// fourth channel, and spending it at rest is what lets the other three stay
    /// loud when they fire.
    ///
    /// **Only ever spent on the body colour, never on an accent.** Opacity on
    /// black is a multiply, so a dimmed accent is not a quieter accent — it is a
    /// colour that appears nowhere in the palette. Rest is `.body`, a near-white,
    /// which dims to a soft grey and stays recognisably itself.
    /// `testAnAccentIsNeverDimmed` is what holds that.
    var isDimmed: Bool

    /// The facts the slot ladder does not carry, because none of them changes
    /// WHICH slot wins — only what the face in it should say.
    struct Ambient: Equatable {
        var isListening = false
        var isThinking = false
        var batteryCritical = false
        var meetingSoon = false
        var isOffline = false
        /// A guided task is running. Nil at every other moment.
        var guide: GuidePresentation.Compact?

        static let none = Ambient()
    }

    static func resolve(slot: CompactSlot, ambient: Ambient) -> BloubFace {
        // 1. Airlock itself, first — a key is physically held or an answer is
        //    being written. It outranks agent state because it is a gesture the
        //    user is making RIGHT NOW, and because it is the one rung that means
        //    anything to somebody who never starts an agent.
        if ambient.isListening || ambient.isThinking {
            return BloubFace(expression: .attentive, tint: .assistant,
                             motion: .working, isDimmed: false)
        }

        // 1b. A guide in progress. Below a held key (the user is speaking to
        //     it, maybe to start the next one) and above agents: the person is
        //     following bloub step by step, so the face beside the steps is
        //     the guide's. The design gives each state its own face.
        if let guide = ambient.guide {
            switch guide {
            case .listening:
                return BloubFace(expression: .attentive, tint: .assistant, motion: .working, isDimmed: false)
            case .looking:
                return BloubFace(expression: .curious, tint: .assistant, motion: .working, isDimmed: false)
            case .guiding(_, _, let offTrack, _):
                return BloubFace(expression: offTrack ? .confused : .attentive,
                                 tint: offTrack ? .attention : .working, motion: .breathing, isDimmed: false)
            case .noProgress:
                return BloubFace(expression: .sleepy, tint: .resting, motion: .still, isDimmed: false)
            case .done:
                return BloubFace(expression: .happy, tint: .done, motion: .still, isDimmed: false)
            }
        }

        // 2. The agent rungs, when the ladder picked one. These are unreachable
        //    with agents switched off — `CompactIslandInput.showsAgents` gates
        //    them — which is exactly why they cannot be the only source.
        switch slot {
        case .completionTick:
            return BloubFace(expression: .happy, tint: .done,
                             motion: .still, isDimmed: false)
        case .agentLamp(let attention, let working):
            // NOT dimmed, even at rest, and that is a change from the lamp this
            // replaced. Opacity over black does not read as "quieter", it reads
            // as a different colour: #3B93F0 at 0.6 composites to #235890, a
            // muddy navy that is nowhere in the palette. The old lamp got away
            // with it because its blue was #5AC8FA, light enough to survive the
            // multiply — the brand blue is not, and the mark has to be the mark.
            //
            // The "is anything happening" distinction it used to carry moves
            // entirely onto MOTION, which is what that channel is for: resting
            // breathes, working blinks.
            let busy = working || attention
            return BloubFace(expression: busy ? .curious : .attentive,
                             tint: attention ? .attention : .working,
                             motion: busy ? .working : .breathing,
                             isDimmed: false)
        default:
            break
        }

        // 3. The machine, for everybody. Ordered by what wants a decision now:
        //    a Mac about to die outranks a meeting, which outranks a network
        //    that is merely absent.
        if ambient.batteryCritical {
            return BloubFace(expression: .scared, tint: .error,
                             motion: .working, isDimmed: false)
        }
        if ambient.meetingSoon {
            return BloubFace(expression: .attentive, tint: .attention,
                             motion: .breathing, isDimmed: false)
        }
        // Dimmed, unlike the two above. Being offline is TRUE rather than
        // urgent — most of this app works without a network — so it changes the
        // face without raising its voice.
        if ambient.isOffline {
            return BloubFace(expression: .confused, tint: .resting,
                             motion: .still, isDimmed: true)
        }

        // 4. At rest. The logo, breathing.
        //
        // **`.attentive`, and neither `.sleepy` nor `.neutral`.** A user who
        // never starts an agent sits here nearly all the time, so whatever face
        // is here is effectively their mascot. Asleep says the app is off while
        // the clipboard, the shelf and voice are all live; neutral's eyes slant
        // away, which reads as bored rather than calm at 34px. Attentive looks
        // straight out, which is what a resting logo should do.
        //
        // **And the brand blue, not the body white** (2026-08-24). The same
        // audience is the reason: `CompactIsland.leading` gates both agent rungs
        // behind `showsAgents`, so somebody who declined agents can never reach
        // blue through them — their mark was this one, permanently, and this one
        // was a near-white at 0.6, which composites to #918F8C. The app icon is
        // #3B93F0. One mark cannot be two colours depending on whether a session
        // happens to exist.
        //
        // Undimmed for the reason the agent lamp is: 0.6 over black is a
        // multiply, and #3B93F0 through it is #235890 — a navy in no palette.
        // Rest stays quieter than work through MOTION, which survives being
        // turned down where a hue does not.
        //
        // The cost, accepted: rest and an idle session now render identically.
        // That is honest — both mean "nothing is happening" — and the
        // distinction worth drawing was always working vs not, which `.curious`
        // and the faster blink still carry.
        //
        // The cost is that expression no longer distinguishes rest from an idle
        // session — colour does that, white against blue — and `.curious` above
        // is what marks the one state where something is actually happening.
        //
        // `.sleepy` and `.neutral` both keep their place in `allCases` and are
        // mapped to by nothing, the same standing `.angry` has.
        return BloubFace(expression: .attentive, tint: .working,
                         motion: .breathing, isDimmed: false)
    }
}
