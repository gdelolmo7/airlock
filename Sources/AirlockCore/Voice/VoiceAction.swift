import Foundation

/// One thing the notch can be asked to do out loud.
///
/// Adding an action is one conformer plus one line in `VoiceActionCatalog` —
/// the same rule as `AgentIntegration` and `NotchWidget`, for the same reason.
///
/// **Everything here is pure and static.** `propose` decides whether a set of
/// arguments describes something doable *right now* and returns a value saying
/// what; it performs nothing, touches no filesystem, and needs no model to
/// test. That is the whole point of the split: the interesting logic is
/// resolving a half-heard phrase against the devices, clips and sessions that
/// actually exist, and that logic is where the bugs are, so it lives somewhere
/// a test can reach it.
public protocol VoiceAction: Sendable {
    /// Policy tool name, and always `Voice.`-prefixed.
    ///
    /// The prefix is not decoration. Claude Code owns `Read`, `Write`, `Edit`,
    /// `Bash`, `Glob`, `Grep` and `WebFetch`, and an `allow: Read` written for
    /// an agent must never authorise a spoken one. It also records provenance:
    /// audio is a lower-trust channel than typing — a call, a podcast, someone
    /// else in the room — so a standing permission should say on its face that
    /// it was granted to a microphone.
    static var toolName: String { get }

    /// One line for the model's catalogue, in the imperative. Costs prompt
    /// tokens on every spoken word, so earn them.
    static var summary: String { get }

    /// Argument names this action reads. Order is the order they are offered to
    /// the model, so put the one it cannot work without first.
    static var parameters: [String] { get }

    /// The spoken shapes that name this action, matched with no model at all.
    ///
    /// Empty means the action can never be reached by voice, which is a valid
    /// thing to be — a conformer with no triggers is one that exists for a model
    /// path that is not switched on.
    static var triggers: [VoiceTrigger] { get }


    /// Non-nil means **no allow rule may ever auto-approve this**, and the
    /// string is the reason shown on the risk badge. Read by `RiskAssessor`, so
    /// there stays exactly one definition of "risky" in the app.
    static var riskFloorReason: String? { get }

    /// How to label the exact rule an "Always" click would write. The subject
    /// itself is already on screen, so this says what the subject *means* —
    /// `Voice.Clipboard(Figma)` allows anything from Figma, not one clip.
    static var exactRuleSummary: String { get }

    /// Nil when the arguments describe nothing doable.
    ///
    /// This is the common case, not the edge: a 3B model asked to fill in a
    /// struct will name a device you do not own and a session that is not
    /// running. Returning nil here is how that becomes "I didn't catch that"
    /// instead of a card promising something impossible.
    static func propose(_ arguments: [String: String], in context: VoiceContext) -> ActionProposal?
}

public extension VoiceAction {
    /// Most actions are ordinary and can be granted standing permission.
    static var riskFloorReason: String? { nil }
    static var exactRuleSummary: String { "Only this exact request" }
    static var triggers: [VoiceTrigger] { [] }
}

// MARK: - Context

/// What exists on this Mac right now, as values.
///
/// Passed in rather than looked up so `propose` stays pure. The app assembles
/// one from its models at the moment of asking; a test writes one by hand.
public struct VoiceContext: Sendable, Equatable {
    public var audioOutputs: [AudioOutputDevice]
    /// **Newest first**, which is NOT the order the clipboard panel renders.
    ///
    /// The panel is pinned-first, because that is the useful order to look at.
    /// Speech addresses this list by recency instead — "the last thing I
    /// copied", "the third thing I copied" — and `VoiceClipboardAction` resolves
    /// both the default and any ordinal on that assumption, so the app sorts
    /// before handing it over.
    public var clipboard: [ClipboardItem]
    public var agentSessions: [VoiceAgentTarget]

    /// The user's Shortcuts, by name.
    ///
    /// The only field whose contents the USER authored, which is what makes
    /// `Voice.Shortcut` different from every other action: Airlock supplies the
    /// verbs everywhere else, and here it supplies none of them. Empty when the
    /// feature is off or the library is — and empty means the action proposes
    /// nothing, rather than guessing at a name.
    public var shortcuts: [String]

    /// Applications that exist on this Mac.
    public var apps: [VoiceAppTarget]

    /// System output volume, 0...1, or nil when the current device has no
    /// software volume. Read by `VoiceVolumeAction` for "turn it down", which
    /// cannot be resolved without knowing where it is now.
    public var volume: Double?

    /// Phrases that mean a web address — shipped defaults merged with the
    /// user's own `~/.airlock/sites.txt`. See `VoiceSiteAliases`.
    public var sites: [VoiceSiteAlias]

    public init(audioOutputs: [AudioOutputDevice] = [],
                clipboard: [ClipboardItem] = [],
                agentSessions: [VoiceAgentTarget] = [],
                shortcuts: [String] = [],
                apps: [VoiceAppTarget] = [],
                sites: [VoiceSiteAlias] = [],
                volume: Double? = nil) {
        self.audioOutputs = audioOutputs
        self.clipboard = clipboard
        self.agentSessions = agentSessions
        self.shortcuts = shortcuts
        self.apps = apps
        self.sites = sites
        self.volume = volume
    }
}

/// A running agent session, reduced to the two things a spoken phrase can
/// address it by. Deliberately not `AgentSession` — this module has no business
/// knowing about sequence numbers or pending gates.
public struct VoiceAgentTarget: Sendable, Equatable, Identifiable {
    public let sessionID: String
    /// What a person would call it out loud. The repo folder, usually.
    public let label: String

    public var id: String { sessionID }

    public init(sessionID: String, label: String) {
        self.sessionID = sessionID
        self.label = label
    }
}

/// An installed application, reduced to the two things a phrase needs: what a
/// person calls it, and enough to open it again later.
///
/// The path rather than a bundle identifier, because the name a person says is
/// the name on the icon — the display name — and going display-name → bundle ID
/// means a lookup that can fail for exactly the apps whose names are unusual.
public struct VoiceAppTarget: Sendable, Equatable, Identifiable {
    /// Filesystem path to the `.app` bundle. Re-checked before opening.
    public let path: String
    /// What it is called on screen, without `.app`.
    public let name: String
    /// What it is called in the OTHER languages the user dictates in —
    /// "Música" for Music.app when Spanish is a dictation language. Read from
    /// the bundle's own localizations (`InstalledApps.scan`), so it exists for
    /// exactly the apps that bothered to localize and is empty for the proper
    /// nouns that never do. Spotify is Spotify everywhere.
    public let aliases: [String]

    public var id: String { path }

    /// Every spoken way to name this app: the on-disk name plus the aliases.
    public var spokenNames: [String] { [name] + aliases }

    public init(path: String, name: String, aliases: [String] = []) {
        self.path = path
        self.name = name
        self.aliases = aliases
    }
}

/// The transport verbs, as values. Deliberately not the app's own
/// `MediaCommand`: that lives in the app target and carries a seek position
/// this path has no way to name out loud.
public enum VoiceMediaCommand: String, Sendable, Equatable {
    case play, pause, next, previous
}

/// What `Voice.Open` resolved to.
public enum VoiceOpenTarget: Sendable, Equatable {
    /// A `.app` bundle path, re-checked before opening.
    case app(path: String)
    /// An absolute http(s) URL. Never any other scheme — `VoiceSiteAliases`
    /// refuses them at parse time, because this string reaches `NSWorkspace`.
    case url(String)
}

// MARK: - Proposal

/// A resolved, doable action awaiting a verdict. Nothing has happened yet.
public struct ActionProposal: Sendable, Equatable {
    public let toolName: String

    /// What a policy rule's pattern globs against, exactly as it will be
    /// written into `Voice.AudioOutput(AirPods Pro)`.
    ///
    /// **Deliberately coarser than the effect in places**, and that is the
    /// design rather than sloppiness. A clipboard subject is the source app,
    /// not the clipped text: a rule naming the text could only ever match that
    /// one string again, which is precisely the dead-rule failure
    /// `RuleGeneralizer` exists to prevent. The card shows the rule before the
    /// Always button is pressed, so nothing widens behind anyone's back.
    public let subject: String

    /// What the user reads before approving. Specific — never "an item".
    public let summary: String

    /// The clipped text, the full prompt, the device. Nil when the summary
    /// already says everything.
    public let detail: String?

    /// What to actually do, once someone says yes.
    public let effect: VoiceEffect

    public init(toolName: String, subject: String, summary: String,
                detail: String? = nil, effect: VoiceEffect) {
        self.toolName = toolName
        self.subject = subject
        self.summary = summary
        self.detail = detail
        self.effect = effect
    }

    /// The seam. Past this line every existing piece — `PolicyEngine`,
    /// `RiskAssessor`, `RuleGeneralizer`, `PolicyStore`, `GateLog` — works
    /// unchanged, because a proposal is just another `PermissionRequest`.
    ///
    /// `command` stays nil: this is not a shell command, and populating it
    /// would put a spoken phrase in front of `RiskAssessor`'s shell regexes,
    /// where "remove the recursive rm from my clipboard" is a false positive
    /// waiting to happen. `target` is the policy subject and the only thing
    /// matched on.
    public func request(id: String, at now: Date) -> PermissionRequest {
        PermissionRequest(id: id, toolName: toolName, summary: summary,
                          target: subject, createdAt: now)
    }
}

/// What performing a proposal actually does.
///
/// A closed enum rather than a closure, so the app's performer is one
/// exhaustive `switch` the compiler checks. Adding an action therefore costs a
/// conformer, a registry line, a case here, and one arm the compiler will
/// demand — which is the honest count, because performing genuinely needs new
/// app capability and cannot be made generic: the decision is pure, the doing
/// touches AppKit.
public enum VoiceEffect: Sendable, Equatable {
    /// Put a clipboard entry back on the pasteboard.
    case copyClipboardItem(id: UUID)
    /// Move system sound output.
    case selectAudioOutput(uid: String)
    /// Send a prompt to a running session, or to a fresh one when nil.
    case sendPrompt(sessionID: String?, text: String)
    /// Set system output volume, 0...1.
    case setVolume(Double)
    /// Play, pause, skip.
    case media(VoiceMediaCommand)
    /// Open something the user named: an app, or a web address.
    ///
    /// One case rather than two because it is one instruction — "open X" — and
    /// which kind of thing X turned out to be is a detail of resolution, not a
    /// different intent. Splitting it would also split the trigger, and two
    /// greedy triggers competing for "open" is precisely the arrangement
    /// `VoiceActionCatalog.offered` documents as unworkable.
    case open(target: VoiceOpenTarget)
    /// Run one of the user's Shortcuts, by its exact name.
    ///
    /// The name rather than an index, because the list is re-enumerated between
    /// proposing and performing and a position would silently shift under a
    /// Shortcut created in the gap.
    case runShortcut(name: String)
}
