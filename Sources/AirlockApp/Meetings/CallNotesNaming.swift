import AirlockCore
import SwiftUI

/// "Who's who": every voice of a meeting, each with something it said to
/// tell it by and a name to give it. Saving puts the names into the notes,
/// the to-dos and the transcript (`MeetingNaming`). The names belong to this
/// meeting alone: no voice is remembered, so none is ever recognised again.
struct CallNotesWhosWho: View {
    @Environment(CallNotesLibrary.self) private var library
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let call: CallNotesLibrary.Call

    @State private var drafts: [Int: CallNotesNameDraft]
    @FocusState private var focused: Int?

    init(call: CallNotesLibrary.Call) {
        self.call = call
        _drafts = State(initialValue: CallNotesNameDraft.all(of: call.record))
    }

    var body: some View {
        let sketches = MeetingNaming.sketches(of: call.record)
        ZStack(alignment: .top) {
            // The window behind waits until this is closed: a click there
            // does nothing, rather than throwing the names away.
            Color.black.opacity(0.58)
                .contentShape(Rectangle())
                .onTapGesture {}
                .accessibilityHidden(true)
            card(sketches)
                .padding(.top, 52)
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
        }
        .task {
            // The first voice nobody has named yet, ready to type into.
            focused = sketches.first { drafts[$0.voice]?.isBlank ?? true }?.voice
        }
    }

    private func card(_ sketches: [MeetingNaming.Sketch]) -> some View {
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Who's who")
                .font(Theme.chrome(17, .bold))
                .foregroundStyle(Theme.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("Give each voice a name. The notes, the to-dos and the transcript change to match.")
                .font(Theme.chrome(12.5))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
                .padding(.bottom, 8)
            // Every voice at once while they fit; a long meeting's scroll.
            ViewThatFits(in: .vertical) {
                rows(sketches)
                ScrollView { rows(sketches) }
                    .scrollIndicators(.automatic)
            }
            CallNotesNaming.hairline
            if sketches.count > 1 {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Two voices that are really one person? Give them the same name and they become one.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(Theme.chrome(11.5))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 10)
                .padding(.bottom, 2)
            }
            if let offering = library.offering, library.offers(call).voicesOnPlus {
                voicesOnPlus { offering.showPlans() }
                    .padding(.top, 10)
                    .padding(.bottom, 2)
            }
            footer
                .padding(.top, 14)
        }
        .padding(.horizontal, 22)
        .padding(.top, 20)
        .padding(.bottom, 16)
        .frame(maxWidth: 600)
        .background(shape.fill(CallNotesNaming.card))
        .overlay(shape.strokeBorder(Color.white.opacity(0.1), lineWidth: 1))
        .shadow(color: .black.opacity(0.6), radius: 30, y: 12)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// On Free, where the whole other side is one voice: Plus would have
    /// told them apart (`CallNotesOffers.voicesOnPlus`).
    private func voicesOnPlus(_ showPlans: @escaping () -> Void) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "person.2")
                .font(.system(size: 11, weight: .medium))
                .accessibilityHidden(true)
            Text(call.record.isInPerson
                 ? String(localized: "More than one person in the room? Plus tells each voice apart: Person 1, Person 2\u{2026}")
                 : String(localized: "More than one person on the other side? Plus tells each voice apart: Person 1, Person 2\u{2026}"))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button(action: showPlans) {
                HStack(spacing: 3) {
                    Text("See Plus")
                    Image(systemName: "chevron.right").font(.system(size: 9.5, weight: .bold))
                }
                .font(Theme.chrome(12, .semibold))
                .foregroundStyle(PlanTag.plusText)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .fixedSize()
        }
        .font(Theme.chrome(11.5))
        .foregroundStyle(Theme.textSecondary)
    }

    private func rows(_ sketches: [MeetingNaming.Sketch]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(sketches, id: \.voice) { sketch in
                row(sketch)
            }
        }
    }

    private func row(_ sketch: MeetingNaming.Sketch) -> some View {
        let seat = CallNotesNaming.seat(of: sketch.voice)
        return HStack(alignment: .top, spacing: 12) {
            CallPersonAvatar(name: sketch.label, seat: seat, size: 30)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(sketch.label)
                        .font(Theme.chrome(12.5, .bold))
                        .foregroundStyle(CallsLook.colour(for: seat))
                    Text(CallNotesNaming.spoke(sketch.turns))
                        .font(Theme.chrome(11, .medium))
                        .foregroundStyle(Theme.textTertiary)
                }
                if let quote = sketch.quote {
                    Text(CallNotesNaming.quote(quote, startedAt: call.record.startedAt))
                        .font(Theme.chrome(13))
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            VStack(alignment: .leading, spacing: 6) {
                CallNotesNameField(draft: binding(sketch.voice), focus: $focused, voice: sketch.voice)
                CallNotesNameChips(draft: binding(sketch.voice), suggestions: sketch.suggestions,
                                   inPerson: call.record.isInPerson) { you in
                    // One voice is you, at most: saying so here takes it
                    // back from any other.
                    guard you else { return }
                    for voice in drafts.keys where voice != sketch.voice && drafts[voice]?.isYou == true {
                        drafts[voice] = CallNotesNameDraft()
                    }
                }
            }
            .frame(width: 190, alignment: .leading)
        }
        .padding(.vertical, 13)
        .overlay(alignment: .top) { CallNotesNaming.hairline }
    }

    private func binding(_ voice: Int) -> Binding<CallNotesNameDraft> {
        Binding(get: { drafts[voice] ?? CallNotesNameDraft() },
                set: { drafts[voice] = $0 })
    }

    private var footer: some View {
        HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 9.5, weight: .semibold))
                    .accessibilityHidden(true)
                Text("Names stay with this meeting. Airlock never remembers voices.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.chrome(11))
            .foregroundStyle(Theme.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            CallNotesNamingButton("Cancel") { close() }
                .keyboardShortcut(.cancelAction)
            CallNotesNamingButton("Save names", primary: true) { save() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func close() {
        withAnimation(Motion.close.animation(reduceMotion: reduceMotion)) { library.naming = nil }
    }

    private func save() {
        let names = CallNotesNameDraft.names(drafts, in: call.record)
        withAnimation(Motion.close.animation(reduceMotion: reduceMotion)) { library.name(call, as: names) }
    }
}

/// A voice's name above what it said, once the call is over: a click says
/// who it is, in a small box beside it.
struct CallTranscriptName: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let voice: Int
    let entry: Int
    let name: String
    let seat: CallPeople.Seat

    @State private var hovered = false

    var body: some View {
        let colour = CallsLook.colour(for: seat)
        let renaming = CallNotesLibrary.Renaming(call: call.id, entry: entry)
        Button { library.renaming = renaming } label: {
            Text(MeetingRecord.shownLabel(name))
                .font(Theme.chrome(12.5, .semibold))
                .foregroundStyle(colour)
                .underline(hovered, color: colour.opacity(0.55))
                .lineLimit(1)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .clickable()
        .help("Say who this is")
        .accessibilityHint("Say who this is")
        .popover(isPresented: Binding(
            get: { library.renaming == renaming },
            set: { shown in
                if !shown, library.renaming == renaming { library.renaming = nil }
            }), arrowEdge: .trailing) {
            CallNotesRename(call: call, voice: voice)
                .environment(library)
        }
    }
}

/// "Who is Person 3?": one voice's name, from the transcript. The same
/// field and suggestions as "Who's who", and the names other voices already
/// have, for a voice that is really one of them.
struct CallNotesRename: View {
    @Environment(CallNotesLibrary.self) private var library
    let call: CallNotesLibrary.Call
    let voice: Int

    var body: some View {
        CallVoiceRename(record: call.record, voice: voice,
                        cancel: { library.renaming = nil },
                        save: { names in library.name(call, as: names) })
    }
}

/// "Who is Person 3?" for any record: the notes window's once the call is
/// over, and the side window's while it goes on. `save` gets every voice's
/// name, this one's new.
struct CallVoiceRename: View {
    let record: MeetingRecord
    let voice: Int
    /// Nil fills the width it is given.
    var width: CGFloat? = 236
    let cancel: () -> Void
    let save: ([MeetingVoiceName]) -> Void

    @State private var draft: CallNotesNameDraft
    @FocusState private var focused: Int?

    init(record: MeetingRecord, voice: Int, width: CGFloat? = 236, cancel: @escaping () -> Void,
         save: @escaping ([MeetingVoiceName]) -> Void) {
        self.record = record
        self.voice = voice
        self.width = width
        self.cancel = cancel
        self.save = save
        _draft = State(initialValue: CallNotesNameDraft.all(of: record)[voice] ?? CallNotesNameDraft())
    }

    var body: some View {
        let sketch = MeetingNaming.sketches(of: record).first { $0.voice == voice }
        let label = record.givenLabel(of: voice) ?? sketch?.label ?? MeetingRecord.personLabel(voice)
        VStack(alignment: .leading, spacing: 0) {
            Text("Who is \(MeetingRecord.shownLabel(label))?")
                .font(Theme.chrome(12.5, .bold))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
                .padding(.bottom, 8)
            CallNotesNameField(draft: $draft, focus: $focused, voice: voice)
            CallNotesNameChips(draft: $draft, suggestions: suggestions(sketch), inPerson: record.isInPerson)
                .padding(.top, 6)
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                CallNotesNamingButton("Cancel", small: true) { cancel() }
                    .keyboardShortcut(.cancelAction)
                CallNotesNamingButton("Save", primary: true, small: true) { saveDraft() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
        .task { focused = voice }
    }

    /// "Same as Marc" for every name another voice has, then what this
    /// voice was heard calling itself and, on a call, the invited.
    private func suggestions(_ sketch: MeetingNaming.Sketch?) -> [CallNotesNameChips.Offer] {
        var offers: [CallNotesNameChips.Offer] = []
        func taken(_ name: String) -> Bool {
            offers.contains { CallNotesNaming.same($0.name, name) }
        }
        for given in record.names where given.voice != voice && !given.isYou && !taken(given.name) {
            offers.append(.init(name: given.name, title: String(localized: "Same as \(given.name)")))
        }
        for suggestion in sketch?.suggestions ?? [] where !taken(suggestion.name) {
            offers.append(.init(suggestion))
        }
        return offers
    }

    private func saveDraft() {
        var drafts = CallNotesNameDraft.all(of: record)
        if draft.isYou {
            for other in drafts.keys where drafts[other]?.isYou == true { drafts[other] = CallNotesNameDraft() }
        }
        drafts[voice] = draft
        save(CallNotesNameDraft.names(drafts, in: record))
    }
}

/// A name as it is being typed, before it is saved.
struct CallNotesNameDraft: Equatable {
    var name = ""
    /// "That's me": the voice is the person's own, in a meeting in the room.
    var isYou = false

    var isBlank: Bool { !isYou && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Every voice of `record`, as it is named now.
    static func all(of record: MeetingRecord) -> [Int: CallNotesNameDraft] {
        Dictionary(uniqueKeysWithValues: record.voices.map { voice in
            let given = record.givenName(of: voice)
            return (voice, CallNotesNameDraft(name: given?.name ?? "", isYou: given?.isYou ?? false))
        })
    }

    /// What `drafts` say, as names to save. A blank one, or one that only
    /// repeats the voice's number ("Person 2"), leaves that voice unnamed;
    /// "you" typed in a meeting in the room is "That's me".
    static func names(_ drafts: [Int: CallNotesNameDraft], in record: MeetingRecord) -> [MeetingVoiceName] {
        drafts.keys.sorted().compactMap { voice in
            guard let draft = drafts[voice] else { return nil }
            let name = MeetingText.oneLine(draft.name)
            let you = draft.isYou
                || (record.isInPerson && CallNotesNaming.same(name, MeetingSpeaker.me.label))
            if you { return MeetingVoiceName(voice: voice, name: "", isYou: true) }
            guard !name.isEmpty, !CallNotesNaming.same(name, MeetingRecord.personLabel(voice)) else { return nil }
            return MeetingVoiceName(voice: voice, name: name)
        }
    }
}

/// Where a name is typed. "You" in its place once "That's me" is on; a
/// click there takes it back to typing.
struct CallNotesNameField: View {
    @Binding var draft: CallNotesNameDraft
    var focus: FocusState<Int?>.Binding
    let voice: Int

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        let isFocused = focus.wrappedValue == voice
        Group {
            if draft.isYou {
                Button {
                    draft = CallNotesNameDraft()
                    focus.wrappedValue = voice
                } label: {
                    HStack(spacing: 7) {
                        CallPersonAvatar(name: MeetingSpeaker.me.label, seat: .you, size: 17)
                        Text(MeetingRecord.shownLabel(MeetingSpeaker.me.label))
                            .font(Theme.chrome(13))
                            .foregroundStyle(Theme.textPrimary)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Type a name instead")
            } else {
                TextField("Name", text: $draft.name, prompt: Text(""))
                    .textFieldStyle(.plain)
                    .font(Theme.chrome(13))
                    .foregroundStyle(Theme.textPrimary)
                    .focused(focus, equals: voice)
                    // A grey hint drawn here, as the search field does: the
                    // field's own placeholder comes out white.
                    .background(alignment: .leading) {
                        if draft.name.isEmpty {
                            Text("Name")
                                .font(Theme.chrome(13))
                                .foregroundStyle(CallsLook.openBox)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                    }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(shape.fill(Color.white.opacity(0.06)))
        .overlay(shape.strokeBorder(isFocused ? Theme.running.opacity(0.75) : Color.white.opacity(0.1),
                                    lineWidth: 1))
        .background {
            if isFocused {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Theme.running.opacity(0.22), lineWidth: 3)
                    .padding(-1.5)
            }
        }
    }
}

/// The names to pick from under a field: "That's me" in a meeting in the
/// room, then the suggestions. A chip lights blue while the field says it.
struct CallNotesNameChips: View {
    struct Offer {
        let name: String
        let title: String
        var symbol: String?

        init(name: String, title: String, symbol: String? = nil) {
            self.name = name
            self.title = title
            self.symbol = symbol
        }

        /// Heard “I'm Marc”, with a sparkle; an invited name as it is.
        init(_ suggestion: MeetingNaming.Sketch.Suggestion) {
            name = suggestion.name
            if let heard = suggestion.heard {
                title = String(localized: "Heard “\(heard)”")
                symbol = "sparkle"
            } else {
                title = suggestion.name
            }
        }
    }

    @Binding var draft: CallNotesNameDraft
    let offers: [Offer]
    let inPerson: Bool
    /// Told whenever "That's me" is pressed, and whether it is now on.
    var onYou: (Bool) -> Void = { _ in }

    init(draft: Binding<CallNotesNameDraft>, suggestions: [MeetingNaming.Sketch.Suggestion],
         inPerson: Bool, onYou: @escaping (Bool) -> Void = { _ in }) {
        self.init(draft: draft, suggestions: suggestions.map(Offer.init), inPerson: inPerson, onYou: onYou)
    }

    init(draft: Binding<CallNotesNameDraft>, suggestions: [Offer], inPerson: Bool,
         onYou: @escaping (Bool) -> Void = { _ in }) {
        _draft = draft
        offers = suggestions
        self.inPerson = inPerson
        self.onYou = onYou
    }

    var body: some View {
        if inPerson || !offers.isEmpty {
            ChipFlow(spacing: 5, rowSpacing: 5) {
                if inPerson {
                    CallNotesNameChip(title: String(localized: "That's me"), symbol: draft.isYou ? "checkmark" : nil,
                                      on: draft.isYou) {
                        let you = !draft.isYou
                        draft = you ? CallNotesNameDraft(isYou: true) : CallNotesNameDraft()
                        onYou(you)
                    }
                }
                ForEach(Array(offers.enumerated()), id: \.offset) { _, offer in
                    CallNotesNameChip(title: offer.title, symbol: offer.symbol,
                                      on: !draft.isYou && CallNotesNaming.same(draft.name, offer.name)) {
                        draft = CallNotesNameDraft(name: offer.name)
                    }
                }
            }
        }
    }
}

private struct CallNotesNameChip: View {
    let title: String
    let symbol: String?
    let on: Bool
    let action: () -> Void

    @State private var hovered = false

    var body: some View {
        let ink = on ? CallsLook.takeText : Theme.textSecondary
        Button(action: action) {
            HStack(spacing: 4) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 8.5, weight: .bold))
                }
                Text(title)
                    .font(Theme.chrome(10.5, .semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(ink)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Capsule().fill(on ? Theme.running.opacity(0.14)
                                           : Color.white.opacity(hovered ? 0.09 : 0.05)))
            .overlay(Capsule().strokeBorder(on ? Theme.running.opacity(0.28) : Color.white.opacity(0.08),
                                            lineWidth: 1))
            .contentShape(Capsule())
            .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .clickable()
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Cancel, and Save in Airlock's blue.
struct CallNotesNamingButton: View {
    let title: LocalizedStringKey
    let primary: Bool
    let small: Bool
    let action: () -> Void

    @State private var hovered = false

    init(_ title: LocalizedStringKey, primary: Bool = false, small: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.primary = primary
        self.small = small
        self.action = action
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
        Button(action: action) {
            Text(title)
                .font(Theme.chrome(small ? 11.5 : 12, .semibold))
                .foregroundStyle(primary ? Color.white : CallsLook.quietText)
                .padding(.horizontal, small ? 10 : 13)
                .frame(height: small ? 24 : 28)
                .background(shape.fill(primary ? CallNotesNaming.primary.opacity(hovered ? 0.88 : 1)
                                               : Color.white.opacity(hovered ? 0.11 : 0.07)))
                .overlay(shape.strokeBorder(Color.white.opacity(primary ? 0 : 0.08), lineWidth: 1))
                .contentShape(shape)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .clickable()
    }
}

@MainActor
enum CallNotesNaming {
    /// The sheet's card, a step lighter than the window.
    static let card = Color(red: 0x16 / 255, green: 0x17 / 255, blue: 0x1C / 255)
    /// Save's blue: Airlock's, deep enough for white words.
    static let primary = Color(red: 0x2F / 255, green: 0x7F / 255, blue: 0xE0 / 255)

    static var hairline: some View {
        Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
    }

    /// A voice keeps its number's colour, named or not (`CallPeople.seat`).
    static func seat(of voice: Int) -> CallPeople.Seat {
        .other(max(0, voice - 1))
    }

    /// "spoke once", "spoke 18 times".
    static func spoke(_ turns: Int) -> String {
        turns == 1 ? String(localized: "spoke once") : String(localized: "spoke \(turns) times")
    }

    /// “What it said.” and, in purple, when: the time of day, as the
    /// transcript says it.
    static func quote(_ quote: MeetingNaming.Sketch.Quote, startedAt: Date) -> AttributedString {
        var said = AttributedString("“\(quote.text)”")
        said.foregroundColor = CallsLook.quietText
        var at = AttributedString("\u{2002}" + CallsCard.time(quote.at, into: startedAt))
        at.foregroundColor = CallsLook.saidText
        at.font = Theme.chrome(10.5, .semibold)
        return said + at
    }

    /// The same name, whatever the case and accents.
    nonisolated static func same(_ one: String, _ other: String) -> Bool {
        let fold = { (text: String) in
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        }
        return fold(one) == fold(other)
    }
}
