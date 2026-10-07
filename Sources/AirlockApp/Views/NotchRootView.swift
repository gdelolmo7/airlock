import SwiftUI
import AirlockCore

/// Content for the DynamicNotchKit surface. The kit draws the black island
/// fused with the physical notch (or a floating capsule) — these views are
/// pure content on that surface, always dark by identity, like the iPhone
/// island. No self-drawn chrome, no adaptive materials.

// MARK: - Expanded

struct NotchExpandedView: View {
    var onCollapse: () -> Void
    /// A drag pinned the panel open; this releases the pin once the drag is
    /// resolved, so the panel goes back to collapsing when you move away.
    var onDragSettled: () -> Void
    var onOpenSettings: () -> Void
    let registry: WidgetRegistry
    @Environment(AppModel.self) private var model
    @Environment(NotchUIState.self) private var uiState
    @Environment(TrayModel.self) private var tray
    @Environment(NotchAppearanceModel.self) private var appearance
    @Environment(DictationModel.self) private var dictation
    @Environment(AssistantModel.self) private var assistant
    @Environment(LicenseModel.self) private var license
    #if AIRLOCK_GUIDE
    @Environment(GuideController.self) private var guide
    #endif
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The guide has the panel: its first look, its card (layout B), or the
    /// sentence it leaves when it stops on its own. Never, without the guide.
    private var guideHasPanel: Bool {
        #if AIRLOCK_GUIDE
        guide.content != nil
        #else
        false
        #endif
    }

    /// The tab stack as last laid out, which is what decides how much of it
    /// may be the part that gives way. See `yieldingRoom(in:)`.
    @State private var stackLayout = PanelStackLayout()
    /// 0 → 1 as a new tab's widgets fade up; rests at 1.
    @State private var tabArrival: Double = 1
    /// The height the panel is held at for the frame a new tab takes to
    /// arrive, then let go inside the Swap so the panel glides to the new
    /// tab's height. Nil — no hold — at rest. See the tab `onChange`.
    @State private var tabHold: CGFloat?
    /// The panel's height as last drawn on each tab: a hold starts from the
    /// tab being LEFT. Not simply the last height — the new tab's first
    /// layout is measured before the change handler runs, so "last" is
    /// already the new tab's.
    @State private var panelHeightOnTab: [NotchTab: CGFloat] = [:]

    private var notice: LicenseNotice { LicenseNotice.forIsland(license.entitlement) }

    var body: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            // Chrome flanking the camera housing, drawn IN the notch band.
            NotchTopBar(reservedWidth: reservedCentreWidth,
                        gutterWidth: gutterWidth,
                        tabs: registry.visibleTabs(),
                        onClear: model.sessions.isEmpty ? nil : { model.clearAllSessions() },
                        onCollapse: onCollapse,
                        onOpenSettings: onOpenSettings)
                .frame(height: bandHeight)

            // While the key is held the panel has exactly one job, so the
            // widgets step aside entirely rather than sitting underneath.
            // Dictation is not a widget — it belongs to a gesture happening in
            // another app — and competing with a calendar for attention is not
            // what you want while watching your own words appear.
            //
            // And through the collapse a hold's end causes, drawing what it
            // last showed — see `NotchUIState.holdDictationThroughCollapse`.
            if dictationOwnsPanel {
                // The same budget the widget stack gets, less the overlay's own
                // chrome — so a long dictation can fill the panel to the bottom
                // of the screen and then scroll, rather than stopping short.
                DictationOverlayView(maxTranscriptHeight: max(80, maxSectionHeight - 52),
                                     frozen: !dictation.showsIndicator)
                    .transition(.opacity)
            }

            // ABOVE the answer, and the only thing that goes there: a widget
            // holding something blocking. An agent is stopped until that card
            // is clicked, and it is drawn first because it is the one with a
            // deadline — anything that will not fit is clipped from the bottom,
            // and the bottom is where the answer is. See `PanelStackContent`.
            //
            // No ScrollView here on purpose. It would be greedy against a
            // budget it has no use for, and put a band of black between the
            // card and the answer; the set is bounded anyway — one widget, and
            // `AgentSessionsSectionView` caps itself at three rows.
            if stackContent == .attentionOnly {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(attentionSections, id: \.id) { section in
                        section.view
                    }
                    // The way back to the whole tab, when what opened the panel
                    // was the question. Under the cards, so it never sits
                    // between you and the one with a deadline.
                    if focusesQuestions {
                        ShowAllAgentsLink { uiState.askingYou = false }
                    }
                }
                // Only the sessions waiting on you, and each without its
                // preview lines: the card under the title says what is asked.
                .environment(\.showsOnlyWaitingSessions, true)
                .padding(.horizontal, 10)
                .transition(.opacity)
            }

            // Same slot, same reasoning: an answer owns the panel while it is
            // up. It cannot coincide with listening — asking begins after the
            // key is released — so the two never compete for the space.
            //
            // And it keeps owning it THROUGH the collapse its dismissal
            // causes: `dismiss` leaves the answer text in place and the
            // controller raises `holdAnswerThroughCollapse` for exactly the
            // conversion's length, so what shrinks away is the answer you
            // were reading — not the home tab, mounted for a final 70ms
            // nobody asked it to fill.
            if assistant.isPresenting || uiState.holdAnswerThroughCollapse,
               !dictationOwnsPanel {
                AssistantView(maxAnswerHeight: answerBudget)
                    .transition(.opacity)
            }

            // First run takes the panel outright — the same way arrange mode
            // replaces the stack rather than overlaying it. A wizard drawn on
            // top of nine widgets is a wizard competing with the thing it is
            // trying to explain, and the height budget does not stretch to
            // both.
            //
            // Deliberately BELOW the attention block above: a gate has a
            // deadline and an agent stopped behind it, which outranks setup.
            // In practice the two rarely meet — the hooks that produce gates
            // are what this step is installing — but "rarely" is not a reason
            // to hide the one card with an agent waiting on it.
            // Also while it is leaving, and then no longer clickable: setup
            // is over, and its buttons would act on a finished wizard. See
            // `NotchUIState.onboardingLeaving`.
            if let onboarding = uiState.onboarding ?? uiState.onboardingLeaving {
                PanelOnboardingView(maxContentHeight: maxSectionHeight, tabs: registry.visibleTabs())
                    .environment(onboarding)
                    .allowsHitTesting(uiState.onboarding != nil)
                    .transition(.opacity)
            }

            // A new version's card takes the panel the same way, once, and
            // yields to setup and to a gate for the same reasons.
            // Also while it is leaving: what shrinks away is the card, not
            // Home. See `NotchUIState.whatsNewLeaving`.
            if let card = uiState.whatsNew ?? uiState.whatsNewLeaving,
               uiState.onboarding == nil, uiState.onboardingLeaving == nil {
                WhatsNewCard(card: card, onDismiss: uiState.dismissWhatsNew)
                    .transition(.opacity)
            }

            // The guide takes the panel the same way, for its first look, its
            // card (layout B) and the sentence it leaves when it stops on its
            // own — and yields to a gate the same way, via `stackContent`.
            #if AIRLOCK_GUIDE
            if guideHasPanel, !panelIsTaken {
                GuidePanelView()
                    .transition(.opacity)
            }
            #endif

            // The selected tab's widgets, in registry order. Scrolls past a cap
            // so a busy day can never grow the panel past the screen — found
            // live: with four sessions plus every widget, the top rows were
            // pushed off-screen entirely.
            //
            // Dropped ENTIRELY while an answer is up, not merely emptied. A
            // ScrollView is greedy vertically, so an empty one still claims the
            // whole `maxSectionHeight` — measured as a panel with a two-line
            // answer at the top and a screen of black beneath it. Dictation
            // drops it the same way since 2026-10-01; it used to keep an
            // emptied region so the height held still, which made a two-second
            // hold the biggest dark panel the app drew.
            //
            // Dropping it is what hid an arriving permission gate for the
            // answer's whole 45 seconds, so what comes back when one arrives is
            // the block above, not this — `PanelStackContent` owns that rule.
            if stackContent == .tab {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 8) {
                    // Everything below is suppressed while listening — see the
                    // overlay above. Hiding the contents rather than the
                    // ScrollView keeps the panel's layout identity stable, so
                    // the transition is a fade rather than a resize.
                    if dictation.showsIndicator { EmptyView() } else {
                    // Above the widgets, not instead of them — and `.none` for
                    // every state except the last days of a trial and a
                    // subscription that is genuinely overdue.
                    LicenseNoticeBanner(notice: notice, tally: model.tally?.tally ?? UsageTally())

                    // **The widgets ARE gated again**, on the owner's decision
                    // (2026-08-21). This branch previously drew the stack
                    // regardless, on the argument that a finished trial should
                    // not take the clipboard, the shelf, the media card and the
                    // calendar with it — nine widgets held hostage for a feature
                    // the person may never have run. That argument is recorded
                    // in full on `Entitlement.allowsUse`, because it is the case
                    // for reverting this if the numbers say so.
                    //
                    // What has NOT changed is that the panel still opens. The
                    // paywall goes where the stack goes, beneath a top bar that
                    // still works, so the app reads as locked rather than as
                    // broken — an `LSUIElement` whose one surface stops
                    // responding cannot be told from one that crashed.
                    if !license.entitlement.allowsUse {
                        LicenseBlockedView(onSubscribe: { license.showPurchase() },
                                           surface: LicenseBlockedView.panel,
                                           subscribedBefore: license.hasSubscribedBefore)
                            .transition(.opacity)
                    } else if uiState.isArranging {
                        // REPLACES the stack rather than overlaying it. The
                        // rows being dragged are stand-ins for the blocks, and
                        // showing both would put two of everything on screen
                        // while one of them silently ignores the pointer.
                        ArrangeModeView(registry: registry, tab: uiState.selectedTab,
                                        onOpenSettings: onOpenSettings)
                            .transition(.opacity)
                    } else {
                    // Full width FIRST — the rail and the media banner are
                    // chrome for the whole tab, not one side of it, and the
                    // levels card reads under them rather than beside them.
                    // They used to sit below the columns, which put a row of
                    // system toggles under the thing they apply to.
                    ForEach(fullWidthSections, id: \.id) { section in
                        section.view
                    }

                    // Paired columns — media beside calendar rather than
                    // stacked, which is what the extra width bought us.
                    if !leadingSections.isEmpty || !trailingSections.isEmpty {
                        // 25, which is the 12 + hairline + 12 this used to be.
                        // The columns keep the gutter they were drawn with; only
                        // the line in the middle of it is gone.
                        HStack(alignment: .top, spacing: 25) {
                            // An empty column claims nothing. Holding its half
                            // open kept the survivor from moving, but the cost
                            // was a blank half-panel whenever the music stopped
                            // — and dead space reads as broken where a reflow
                            // only reads as responsive.
                            if !leadingSections.isEmpty { column(leadingSections, in: .leading) }
                            // No rule between them.
                            //
                            // It was a `Rectangle().frame(width: 1)` with no
                            // height, so it took the HStack's — which is the
                            // TALLER column. Every card here already carries its
                            // own `Theme.rowStroke`, so the line was redundant
                            // whenever the columns matched and wrong whenever
                            // they did not: once the levels card learned to
                            // collapse to ~62pt beside a ~230pt calendar, it
                            // bordered about 170pt of nothing.
                            //
                            // Matching it to the SHORTER column needs both
                            // heights. They are measured now, for the room the
                            // System list is offered (`PanelStackLayout`), but a
                            // hairline is still not worth drawing where two
                            // strokes and 25pt of air already do its work.
                            if !trailingSections.isEmpty { column(trailingSections, in: .trailing) }
                        }
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    // A tab with nothing in it left a blank panel and no way
                    // out — the settings that fix it are behind a gear most
                    // people won't connect to the emptiness in front of them.
                    if leadingSections.isEmpty, trailingSections.isEmpty, fullWidthSections.isEmpty {
                        EmptyTabView(anyEnabled: registry.hasEnabledWidgets(tab: uiState.selectedTab),
                                     onOpenSettings: onOpenSettings)
                    }
                    } // end: arranging replaces the stack
                    } // end: suppressed while listening
                }
                .padding(.horizontal, 10)
                // A new tab's widgets fade up into place rather than replacing
                // the last tab's in one frame (owner, 2026-10-04). Opacity and
                // a 4pt offset only, both render-time: nothing here changes
                // the stack's measured height. The panel's height glides on
                // its own, through the tab hold below (card C4).
                //
                // A @State that RESTS at 1, never a keyframeAnimator: build
                // 627 used one, and on the real notch the stack went black on
                // every tab change — its clock evidently never ran in this
                // panel, so the stack sat on its first keyframe, 0. Here the
                // model value is 1 the moment the change lands, so the worst a
                // stalled animation can do is skip the fade.
                //
                // A Swap (`Motion`): the frame glides to the new height, the
                // content rises 4pt into place. Under Reduce Motion it is the calm version — the
                // fade alone, nothing moving.
                .opacity(tabArrival)
                .offset(y: reduceMotion ? 0 : (1 - tabArrival) * Motion.swapLift)
                .onChange(of: uiState.selectedTab) { left, _ in
                    var instant = Transaction()
                    instant.disablesAnimations = true
                    // The panel GLIDES to the new tab's height (card C4): held
                    // where it was for the first frame, then let go inside the
                    // Swap below, so the release is what animates. Measured
                    // before this, the height snapped in one frame — 408pt to
                    // 176pt between two pictures. The content does not cross-
                    // fade, so no frame shows the old tab: the new one is
                    // drawn at once at opacity 0, inside the held height.
                    // Calm under Reduce Motion: no hold, the fade alone.
                    withTransaction(instant) {
                        tabArrival = 0
                        if !reduceMotion { tabHold = panelHeightOnTab[left] }
                    }
                    HoverTrace.note("tab → \(uiState.selectedTab)")
                    // Started a frame later, so it starts AFTER the new tab's
                    // first draw. Started at once, a heavy tab (the clipboard's
                    // two hundred rows) spent the first part of the fade being
                    // built, so each tab seemed to fade at its own speed
                    // (owner, 2026-10-04). A main-actor task cannot resume
                    // while that draw is still running, so the 16ms is a floor.
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 16_000_000)
                        withAnimation(Motion.swap.animation(reduceMotion: reduceMotion)) {
                            tabArrival = 1
                            tabHold = nil
                        }
                    }
                }
                // The full-width band's room; each column sets its own.
                .environment(\.yieldingContentRoom, yieldingRoom(in: .fullWidth))
                .background {
                    GeometryReader { geo in
                        Color.clear.preference(key: PanelStackLayoutKey.self,
                                               value: .stack(geo.size.height, tab: uiState.selectedTab.rawValue))
                    }
                }
                .onPreferenceChange(PanelStackLayoutKey.self) { layout in stackLayout = layout }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .ticksAtScrollEnds()
            .frame(maxHeight: maxSectionHeight)
            }

            // AI-first quick prompt — on the agents tab, where a prompt belongs.
            // Not while dictating: it is a text field you cannot reach without
            // letting go of the key, and it would take height from the
            // transcript that is the only thing you are looking at.
            if uiState.selectedTab == .agents, !dictationOwnsPanel, !assistant.isPresenting,
               !uiState.holdAnswerThroughCollapse, !panelIsTaken,
               !assistant.isCommandBarOpen, !notice.isBlocking, stackContent != .attentionOnly {
                QuickPromptBar().environment(model)
            }

            // The typed way into the resolver. Any tab — it is summoned by a
            // hotkey rather than found, so tying it to one tab would mean the
            // hotkey silently did nothing on the other three. Suppressed while
            // dictating for the reason above, and while a licence blocks use,
            // since everything it could do is exactly what is blocked.
            if showsCommandBar {
                CommandBar()
            }
        }
        // Cancel the kit's top safeAreaInset so we draw from the physical screen
        // top and own the notch band ourselves — that band is where the gutters
        // live. Without this the top bar lands BELOW the housing and the whole
        // point is lost. The inset is exactly `foreignTopInset`, so this nets to
        // zero rather than being a fudge.
        .padding(.top, -metrics.foreignTopInset)
        .padding(.bottom, Self.bottomPadding)
        .frame(width: appearance.panelWidth)
        // How far the content overran the backstop below, for `FrameWatch`:
        // a stack reports its children's height even when it was offered
        // less, so measured HERE it is the height the backstop then cuts.
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            uiState.panelOverflow = max(0, height - maxPanelHeight)
        }
        // The tab hold, on the whole panel rather than the stack: the agents
        // tab's prompt bar comes and goes with the tab too, and held only
        // below it the panel still jumped by the bar's height. The stack's
        // scroll view takes up whatever the hold leaves over or short.
        .frame(height: tabHold, alignment: .top)
        .onGeometryChange(for: CGFloat.self, of: \.size.height) { height in
            // Only at rest: a held height belongs to the tab being left.
            if tabHold == nil { panelHeightOnTab[uiState.selectedTab] = height }
        }
        // Over-drawn past our own bounds to cover the kit's opaque black, which
        // is not configurable and would otherwise be the only thing the glass
        // had to blur. Clipped by the kit's NotchShape mask, so it can't escape.
        .background { appearance.surface.background.padding(-70) }
        // Flips the whole palette for light glass — Theme resolves against the
        // effective appearance.
        .environment(\.colorScheme, appearance.surface.colorScheme)
        // Backstop. The section cap below is what normally binds; this catches
        // chrome that outgrew its budget.
        .frame(maxHeight: maxPanelHeight, alignment: .top)
        // LOAD-BEARING, and paired with `Theme.textScale`. Views cannot observe
        // a static, so without this the text-size slider moves nothing at all —
        // and, worse than nothing, a parent re-render for some unrelated reason
        // would rebuild section headers with the new scale while SwiftUI skipped
        // unchanged rows, giving a panel that is half-scaled and reads as
        // "mostly working". Re-identifying the whole subtree is what makes the
        // setting take effect atomically. See `Theme.textScale`.
        .id(appearance.textScale)
        // The whole panel takes a drop, not just the tray tab's tiles: by the
        // time you're mid-drag the panel has only just appeared under your
        // cursor, and aiming at a grid that wasn't there a moment ago is a poor
        // ask. Anywhere lands, and we switch to the tray so you see where it went.
        //
        // And it takes exactly what the cutout takes — one list, one classifier,
        // one answer. See `TrayPanelDropTarget`.
        .onDrop(of: TrayPanelDropTarget.contentTypes,
                delegate: TrayPanelDropTarget(tray: tray, uiState: uiState,
                                              onSettled: onDragSettled))
        // A Swap: a session arriving or leaving is the list making room, and
        // a list that teleports loses which row moved. No overshoot — inside
        // a height-capped panel that would be genuine vertical travel — and
        // the calm fade under Reduce Motion.
        .animation(Motion.swap.animation(reduceMotion: reduceMotion),
                   value: model.sessions)
    }

    // MARK: - Sections

    /// How much of the tab there is room for right now. The whole reason this
    /// is a resolved value rather than `!assistant.isPresenting` is the gate
    /// case — see `PanelStackContent`.
    private var stackContent: PanelStackContent {
        // `holdAnswerThroughCollapse` counts as answering: the collapse the
        // dismissal caused is still running, and the widgets must not mount
        // under it — see the answer block above.
        PanelStackContent.resolve(dictating: dictationOwnsPanel,
                                  answering: assistant.isPresenting || uiState.holdAnswerThroughCollapse,
                                  demandsAttention: registry.demandsAttention,
                                  onboarding: panelIsTaken,
                                  guiding: guideHasPanel,
                                  typing: showsCommandBar,
                                  askingYou: focusesQuestions)
    }

    /// Dictation's surface is on screen: a hold, its notice or card, or the
    /// collapse one of those just caused. An answer or the guide arriving
    /// takes the panel straight back. Read wherever the stack used to read
    /// `showsIndicator`, so nothing mounts under the shrinking surface.
    private var dictationOwnsPanel: Bool {
        dictation.showsIndicator
            || (uiState.holdDictationThroughCollapse && !assistant.isPresenting
                && !guideHasPanel && !panelIsTaken)
    }

    /// The panel is open on the Agents tab because an agent is asking. Read by
    /// the stack rule, by the prompt bar, and by the "Show all" link.
    private var focusesQuestions: Bool {
        uiState.askingYou && uiState.selectedTab == .agents
    }

    /// The typing bar is on screen. One definition, read by the stack rule and
    /// by the bar's own `if`, so the two cannot disagree about an empty notch.
    private var showsCommandBar: Bool {
        assistant.isCommandBarOpen && !dictationOwnsPanel && !notice.isBlocking
            && !panelIsTaken
    }

    /// Setup or a new version's card owns the panel: the widget stack, the
    /// guide and the typing bars all stand aside for either.
    private var panelIsTaken: Bool {
        uiState.onboarding != nil || uiState.onboardingLeaving != nil
            || uiState.whatsNew != nil || uiState.whatsNewLeaving != nil
    }

    private var leadingSections: [(id: String, view: AnyView)] {
        registry.sections(stackContent, in: .stack, tab: uiState.selectedTab, column: .leading)
    }

    private var trailingSections: [(id: String, view: AnyView)] {
        registry.sections(stackContent, in: .stack, tab: uiState.selectedTab, column: .trailing)
    }

    private var fullWidthSections: [(id: String, view: AnyView)] {
        registry.sections(stackContent, in: .stack, tab: uiState.selectedTab, column: .full)
    }

    /// Every column's blocking sections, in one column.
    ///
    /// Pairing two side by side is a layout for a full tab. What is left here is
    /// a card that has to be read and clicked, so it gets the width — and the
    /// concatenation means a future blocking widget in either column is drawn
    /// rather than quietly dropped for sitting on the wrong side.
    private var attentionSections: [(id: String, view: AnyView)] {
        [WidgetColumn.leading, .trailing, .full].flatMap {
            registry.sections(.attentionOnly, in: .stack, tab: uiState.selectedTab, column: $0)
        }
    }

    /// Fills whatever width it is given, so a lone column spans the panel.
    ///
    /// Measured, and handed its own room for the content that gives way: a
    /// column's rows cost nothing while the other column is the taller one,
    /// which the stack-wide figure cannot know. See `PanelStackLayout`.
    private func column(_ sections: [(id: String, view: AnyView)],
                        in side: PanelStackLayout.Region) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(sections, id: \.id) { section in
                section.view
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .environment(\.yieldingContentRoom, yieldingRoom(in: side))
        .environment(\.fillsPairedRow, fillsPairedRow(sections))
        .background {
            GeometryReader { geo in
                Color.clear.preference(key: PanelStackLayoutKey.self,
                                       value: .column(side, height: geo.size.height))
            }
        }
        .transformPreference(PanelStackLayoutKey.self) { layout in layout.claimYielding(for: side) }
    }

    /// A lone card beside another column on Home fills the row, so Sound
    /// ends level with the controls beside it rather than at half their
    /// height (the owner's call, 2026-10-01).
    ///
    /// **Home only, on purpose.** A filled column reports the row's height to
    /// `PanelStackLayout`, and beside the System card's list — whose room is
    /// worked out from the other column's height — that would feed back into
    /// itself. System lives on the Dashboard, and a widget's tab is fixed in
    /// code, so on Home the loop cannot form.
    private func fillsPairedRow(_ sections: [(id: String, view: AnyView)]) -> Bool {
        uiState.selectedTab == .home && sections.count == 1
            && !leadingSections.isEmpty && !trailingSections.isEmpty
    }

    // MARK: - Geometry
    //
    // Every number below comes from `NotchMetrics` or a named chrome constant.
    // Nothing here reads `safeAreaInsets.top` — see `NotchMetrics` for why that
    // reading is not the notch height.

    /// `islandMetrics`, not `notchMetrics`: on a monitor the kit draws around a
    /// stand-in cutout and adds ITS height above us, so that is what the top
    /// padding has to cancel. On the notch the two are the same value.
    private var metrics: NotchMetrics { NotchScreen.notched.islandMetrics }

    /// The band the camera housing sits in. The top bar occupies exactly this,
    /// so its gutters are level with the housing rather than below it.
    private var bandHeight: CGFloat { max(metrics.notchHeight, Self.minBandHeight) }

    /// Space held clear for the housing. `notchWidth` is the measured cutout;
    /// tightening trades safety margin for gutter width. Too tight and the
    /// gutters' inner edges disappear behind the camera.
    private var reservedCentreWidth: CGFloat { appearance.reservedCentreWidth }

    private var gutterWidth: CGFloat { appearance.gutterWidth }

    /// We cancel the host's top inset and draw from the screen top, so the
    /// budget is the whole host panel less what it reserves beneath us.
    private var maxPanelHeight: CGFloat {
        metrics.fullBleedContentBudget(hostBottomInset: NotchHost.bottomInset, margin: NotchHost.safetyMargin)
    }

    /// Fixed chrome above and below the scroll region, inside `maxPanelHeight`.
    ///
    /// Tab-aware because the quick prompt only renders on the agents tab.
    /// Reserving it everywhere cost Home and Tray 38pt of scroll region — the
    /// bar's height plus the VStack gap that also isn't there — for a row that
    /// was never going to be drawn.
    private var chromeHeight: CGFloat {
        let showsPrompt = uiState.selectedTab == .agents
        // One gap under the top bar, one over the prompt bar, and one more when
        // a blocking card is sharing the region with an answer.
        let gaps = 1 + (showsPrompt ? 1 : 0) + (stackContent == .attentionOnly ? 1 : 0)
        return bandHeight
            // Scaled, because the quick-prompt bar is a TEXT FIELD and grows
            // with the setting while this constant would not. Under-reporting
            // chrome does not overflow gracefully: `maxSectionHeight` is what
            // makes the widget region scroll, so too large a region pushes the
            // prompt bar past the bottom of the panel, where the outer
            // `maxPanelHeight` frame CLIPS it rather than scrolling it. The
            // symptom is a text field cut in half at the screen edge, on the
            // agents tab only, at large scales only.
            + (showsPrompt ? Self.quickPromptHeight * Theme.textScale : 0)
            + (CGFloat(gaps) * Self.rowSpacing)
            + Self.bottomPadding
    }

    /// What's left for sessions and widgets. This is the cap that normally
    /// binds, and the one that makes the region scroll instead of overflow.
    private var maxSectionHeight: CGFloat { max(120, maxPanelHeight - chromeHeight) }

    /// How tall the content that gives way may grow where it sits — today, the
    /// System section's list of apps, which shows fewer rows rather than push
    /// the rest of the tab out of view. The arithmetic, and why it never counts
    /// the list against itself, is `PanelStackLayout`'s.
    private func yieldingRoom(in region: PanelStackLayout.Region) -> CGFloat {
        stackLayout.yieldingRoom(in: region, budget: maxSectionHeight, tab: uiState.selectedTab.rawValue)
    }

    /// The scrollable part of an answer, once its own chrome is paid for.
    ///
    /// It gives ground when a gate is sharing the region. The gate block above
    /// is content-sized, so without a reservation the answer would go on asking
    /// for the whole budget and the pair would run past `maxPanelHeight` — which
    /// clips rather than scrolls. Shrinking the answer is fine and deleting it
    /// is not, which is why this is a smaller share rather than a dropped view.
    private var answerBudget: CGFloat {
        let region = stackContent == .attentionOnly ? maxSectionHeight * 0.5 : maxSectionHeight
        return max(80, region - Self.answerChrome)
    }

    private static let rowSpacing: CGFloat = 8
    /// The answer card's own header, actions row and padding, around the text.
    private static let answerChrome: CGFloat = 64
    private static let bottomPadding: CGFloat = 6
    private static let quickPromptHeight: CGFloat = 30
    /// Notch-less displays still need a usable bar.
    private static let minBandHeight: CGFloat = 26

}

// MARK: - Room for the content that gives way

/// The tab stack's layout, measured inside the scroll view: the stack, each
/// column, and the content that gives way, each reported by the view that can
/// see it and merged on the way up (`PanelStackLayout.merge`).
struct PanelStackLayoutKey: PreferenceKey {
    static let defaultValue = PanelStackLayout()
    static func reduce(value: inout PanelStackLayout, nextValue: () -> PanelStackLayout) {
        value.merge(nextValue())
    }
}

extension EnvironmentValues {
    /// How tall the content that gives way may be where it sits — see
    /// `PanelStackLayout.yieldingRoom`. Unbounded outside the panel, which is
    /// where a snapshot draws.
    @Entry var yieldingContentRoom: CGFloat = .infinity
    /// The card is alone in its column beside another one on Home, and should
    /// fill the row's height so the two cards end level (`HomeCardBackground`).
    @Entry var fillsPairedRow = false
    /// The panel opened for what is waiting on you (`PanelStackContent
    /// .attentionOnly`): the session list keeps only the sessions asking, and
    /// their cards drop the preview lines.
    @Entry var showsOnlyWaitingSessions = false
}

extension View {
    /// Reports this view as content that gives way when the panel's stack runs
    /// short of room, so the room it is offered never counts it.
    func reportsYieldingHeight() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: PanelStackLayoutKey.self, value: .yielding(geo.size.height))
            }
        }
    }
}

/// The agents widget's panel block: the session list (attention-sorted,
/// capped so the island never becomes a column) or the empty-state hint.
struct AgentSessionsSectionView: View {
    @Environment(AppModel.self) private var model
    @Environment(AgentsWidgetModel.self) private var agents

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Above the sessions: the figures it is about sit over every tab,
            // frozen, and this is the only place that says why.
            if agents.usageStopped {
                ProblemCard(icon: "gauge.with.dots.needle.33percent",
                            sentence: UsageReadout.stoppedSentence,
                            tone: .needs,
                            button: UsageReadout.restoreButton,
                            action: { agents.restoreUsage() })
            }
            if model.sessions.isEmpty {
                AgentsEmptyState(connection: agents.connection,
                                 onStart: { model.startClaudeSession() })
            } else {
                AgentSessionsList(sessions: model.sessions)
            }
        }
        // A conflict is fixed by hand, in a file, while the app runs — and
        // another tool takes the usage link the same way.
        .onAppear { agents.refreshConnection() }
    }
}

/// The Agents tab with no sessions, which is three different situations and
/// used to be drawn as one ("No agents running", over a setup that could never
/// show a session as readily as over a healthy one):
///
/// - nothing connected — the connect card, whether the tab is here because
///   nobody has been asked yet or because Developer mode was switched on;
/// - an agent whose settings file Airlock won't touch — said, with the file;
/// - connected, and nothing running — which agents are connected, and a way
///   to start one.
///
/// Values in (`AgentsConnection`), so the state gallery draws each one.
struct AgentsEmptyState: View {
    let connection: AgentsConnection
    var onStart: () -> Void = {}
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let trouble = model.terminalTrouble {
                TerminalTroubleCard(trouble: trouble)
            }
            ForEach(connection.blocked, id: \.name) { link in
                ProblemCard(icon: "exclamationmark.triangle",
                            sentence: AgentsConnection.blockedSentence(link),
                            tone: .needs,
                            button: Self.showFile,
                            action: { Self.reveal(link.settingsPath) })
            }
            if connection.isNothingConnected {
                AgentsUnwiredCard()
            } else if !connection.connected.isEmpty {
                AgentsEmptyCard(line: connection.emptyLine, onStart: onStart)
            }
        }
    }

    static let showFile = "Show the file"

    /// Finder, with the file selected — the fix is an edit somebody makes
    /// themselves, and Airlock does not edit lines it did not write.
    private static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}

/// The sessions themselves — values in, so a snapshot draws exactly this.
///
/// Live sessions get a card each, at most three; finished ones share one
/// compact card underneath. Gates sort first (`SessionState.ordered`), so the
/// cap can never push one out of sight. The rest are one click away — the
/// count under the list used to be plain text, naming sessions there was no
/// way to see.
struct AgentSessionsList: View {
    let sessions: [AgentSession]
    @Environment(AppModel.self) private var model
    @Environment(\.showsOnlyWaitingSessions) private var onlyWaiting
    @State private var showsAll = false

    private static let liveCap = 3
    private static let finishedCap = 3

    var body: some View {
        let shown = onlyWaiting ? sessions.filter(\.status.wantsAttention) : sessions
        let live = shown.filter { !SessionRowView.isRetired($0) }
        let finished = shown.filter(SessionRowView.isRetired)
        let hidden = max(0, live.count - Self.liveCap) + max(0, finished.count - Self.finishedCap)
        let liveCap = showsAll ? live.count : Self.liveCap
        let finishedCap = showsAll ? finished.count : Self.finishedCap

        VStack(alignment: .leading, spacing: 8) {
            if let trouble = model.terminalTrouble {
                TerminalTroubleCard(trouble: trouble)
            }
            ForEach(live.prefix(liveCap)) { session in
                SessionRowView(session: session)
            }
            if !finished.isEmpty {
                FinishedSessionsCard(sessions: Array(finished.prefix(finishedCap)))
            }
            if hidden > 0 {
                Button { showsAll.toggle() } label: {
                    HStack(spacing: 3) {
                        Text(showsAll ? "Show fewer"
                             : hidden == 1 ? "Show 1 more session" : "Show \(hidden) more sessions")
                        Image(systemName: showsAll ? "chevron.up" : "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(Theme.chrome(10.5, .semibold))
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .clickable()
            }

            // BELOW the sessions, never above. It is an offer about work
            // already finished, and putting it over a session that is waiting
            // would give a convenience the position that belongs to a gate.
            if !onlyWaiting, let suggestion = model.ruleSuggestion {
                RuleSuggestionCard(
                    suggestion: suggestion,
                    onAccept: { candidate, projectOnly in
                        model.acceptSuggestion(suggestion, candidate: candidate,
                                               projectOnly: projectOnly)
                    },
                    onDecline: { model.declineSuggestion(suggestion) })
            }
        }
    }
}

/// Under the waiting cards when an agent opened the panel to ask: the way to
/// the whole Agents tab, which the question view leaves out on purpose.
struct ShowAllAgentsLink: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 3) {
                Text("Show all agents")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(Theme.chrome(10.5, .semibold))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .clickable()
        .accessibilityHint("Shows every session, the branch and the prompt bar")
    }
}

/// Connected and nothing is running: which agents are connected, and a way to
/// start one. The green check is what tells it apart from the connect card
/// at a glance — the two used to share a sparkle and a sentence.
struct AgentsEmptyCard: View {
    /// `AgentsConnection.emptyLine`: which agents, said.
    let line: String
    var onStart: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Theme.done)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Theme.done.opacity(0.13)))
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("No agents running")
                    .font(Theme.chrome(13, .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text(line)
                    .font(Theme.chrome(11.5))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            Button(action: onStart) {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("New Claude session")
                        .font(Theme.chrome(11.5, .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .frame(height: 28)
                .background(Capsule().fill(Theme.running))
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .clickable()
            .fixedSize()
            .help("Opens a new terminal with Claude Code running in it.")
        }
        .modifier(HomeCardBackground())
    }
}

/// The Agents tab on a Mac where no coding agent is connected (no hooks).
///
/// This tab exists at all only because of `AgentsWidget.isUnconfigured` — the
/// deliberate exception to "a tab whose widgets are all off leaves the strip".
/// The footnote is part of the design, not decoration: a surface that appears
/// without being asked for has to say how to make it go away.
struct AgentsUnwiredCard: View {
    @Environment(AgentsWidgetModel.self) private var agents

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.needs)

                VStack(alignment: .leading, spacing: 3) {
                    Text("No coding agent is connected yet")
                        .font(Theme.chrome(12.5, .semibold))
                        .foregroundStyle(Theme.textPrimary)
                    Text(explanation)
                        .font(Theme.chrome(11.5))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 4)

                Button { agents.installHooks() } label: {
                    Text(connectLabel)
                        .font(Theme.chrome(12, .semibold))
                        .foregroundStyle(Color(red: 0.14, green: 0.09, blue: 0.01))
                        .padding(.horizontal, 12)
                        .frame(height: 27)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.needs))
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .clickable()
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.needs.opacity(0.07))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Theme.needs.opacity(0.28), lineWidth: 1))
            )

            if let error = agents.installError {
                ProblemCard(sentence: error, tone: .stopped,
                            button: "Try again", action: { agents.installHooks() })
            }

            HStack(alignment: .top, spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 9, weight: .medium))
                Text("Don't use coding agents? Switch them off in Settings and this tab goes away.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.chrome(10.5))
            .foregroundStyle(Theme.textTertiary)
            .padding(.horizontal, 2)
        }
    }

    /// Names the agent only when one is actually installed — see
    /// `AgentsWidgetModel.unwiredAgentNames`.
    private var explanation: String {
        let names = agents.unwiredAgentNames
        switch names.count {
        case 0:
            return "Connect Claude Code or Codex and you'll see what it's doing here, and answer what it asks."
        case 1:
            return "\(names[0]) is on this Mac. Connect it and you'll see what it's doing here, and answer what it asks."
        default:
            return "\(names.joined(separator: " and ")) are on this Mac. Connect them and you'll see what they're doing here, and answer what they ask."
        }
    }

    /// Named after the one agent it will connect, so the button says what it
    /// does (`docs/how-airlock-talks.md`); plain "Connect" when it is several
    /// or none is installed yet.
    private var connectLabel: String {
        let names = agents.unwiredAgentNames
        return names.count == 1 ? "Connect \(names[0])" : "Connect"
    }
}

// MARK: - Compact (beside the physical notch; tap either side to expand)

struct NotchCompactLeadingView: View {
    var onTap: () -> Void
    @Environment(AppModel.self) private var model
    // Read for the FACE rather than the slot — see `BloubFace.Ambient`. Voice
    // and the network are what give the character something to say to somebody
    // who never starts an agent.
    @Environment(DictationModel.self) private var dictation
    @Environment(AssistantModel.self) private var assistant
    @Environment(SystemControlsModel.self) private var controls
    @Environment(MediaWidgetModel.self) private var media
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(AgentsWidgetModel.self) private var agents
    // Read by the shared input rather than by this slot. Both halves resolve
    // against ONE value — that is what stops them disagreeing — so both declare
    // everything it reads, and a missing one traps at runtime.
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(TrayModel.self) private var tray
    @Environment(AudioOutputModel.self) private var output
    @Environment(SoundWidgetModel.self) private var sound
    @Environment(NotchUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slot: CompactSlot {
        CompactIsland.leading(model.compactIslandInput(
            media: media, calendar: calendar, agents: agents, battery: battery,
            tray: tray, output: output, sound: sound, controls: controls, ui: ui))
    }

    var body: some View {
        CompactLeadingGlyph(slot: slot, ambient: { ambient },
                            artworkURL: { media.state?.artworkURL })
        // Keyed off the RESOLVED slot, exactly like the trailing half below.
        // `ui.completionTick` covered only the tick arriving and leaving; every
        // other swap this slot makes — a paused track retiring into the meeting
        // icon, the lamp arriving over artwork — snapped instead of settling.
        // Never key off the input: it carries a `Date` that moves whenever a
        // transient window is open, so keying off it would animate on redraws.
        //
        // And NOT while the kit is converting. An animated swap is a branch
        // insertion with a transition — the default `.opacity` one, declared
        // nowhere — and a transition begun inside a conversion can strand the
        // branch at opacity 0: the spoken-media blank island. Unanimated, the
        // swap gets no transition at all and cannot. See
        // `NotchUIState.panelConverting`.
        .animation(ui.panelConverting ? nil
                       : Motion.swap.animation(reduceMotion: reduceMotion),
                   value: slot)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
        // One element, not a shape with a tap on it. `children: .ignore` because
        // the lamp and the tick are drawings — there is nothing underneath worth
        // reading, and the slot's own label is the meaning.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(slot.accessibilityLabel ?? "Airlock")
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens the panel")
    }

    private var ambient: BloubFace.Ambient {
        BloubFace.Ambient(
            isListening: dictation.showsIndicator,
            isThinking: assistant.isPresenting,
            // Derived exactly as `AppModel.compactIslandInput` derives them, so
            // the face and the slot cannot disagree about the same fact.
            batteryCritical: battery.state?.isCritical == true,
            meetingSoon: calendar.glanceEvent != nil,
            // `hasResolvedNetwork` guards the first beat after launch, when no
            // path has arrived and "offline" would be a guess rather than a fact.
            isOffline: controls.hasResolvedNetwork && !controls.network.isSatisfied,
            guide: ui.guideCompact)
    }

}

struct NotchCompactTrailingView: View {
    var onTap: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(MediaWidgetModel.self) private var media
    @Environment(CalendarWidgetModel.self) private var calendar
    @Environment(AgentsWidgetModel.self) private var agents
    @Environment(BatteryWidgetModel.self) private var battery
    @Environment(TrayModel.self) private var tray
    @Environment(AudioOutputModel.self) private var output
    @Environment(SoundWidgetModel.self) private var sound
    // Read by the shared input, not by the drawing: `isAwake` is the keep-awake
    // rung. Both halves declare everything the input reads — see the leading
    // half — and `withEveryModel` injects it into this tree like every other.
    @Environment(SystemControlsModel.self) private var controls
    /// The slot itself reads none of this — the input both halves resolve
    /// against is one value on purpose, which is what stops them disagreeing —
    /// but the `.animation` below reads `ui.panelConverting`.
    @Environment(NotchUIState.self) private var ui
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var slot: CompactSlot {
        CompactIsland.trailing(model.compactIslandInput(
            media: media, calendar: calendar, agents: agents, battery: battery,
            tray: tray, output: output, sound: sound, controls: controls, ui: ui))
    }

    var body: some View {
        CompactTrailingGlyph(slot: slot,
                             meetingStart: { calendar.glanceEvent?.start },
                             waveLevels: { media.waveLevels })
        // Keyed off the RESOLVED slot, never off the input: the input carries a
        // `Date` that moves on every redraw, so keying off it would animate
        // continuously. `CompactSlot` changes when something actually changed.
        // Unanimated while the kit converts, or the swap's transition can
        // strand at opacity 0 — see the leading slot and
        // `NotchUIState.panelConverting`.
        .animation(ui.panelConverting ? nil
                       : Motion.swap.animation(reduceMotion: reduceMotion),
                   value: slot)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        // On a call, a click goes to the call: the pill's one job is getting
        // you back to the window you are talking in. Anything else, or a call
        // whose app has gone, opens the panel as before.
        .onTapGesture {
            if case .call = slot, model.calls.bringForward() { return }
            onTap()
        }
        // `.combine` rather than the leading slot's `.ignore`, and the label is
        // conditional, because of one case: the meeting countdown's minutes come
        // from a `TimelineView` clock, so the live "5m" text is a better thing to
        // read than any fixed phrase this level could supply.
        .accessibilityElement(children: .combine)
        .modifier(SlotLabel(slot.accessibilityLabel))
        .accessibilityAddTraits(.isButton)
        .accessibilityHint(slot.isCall ? "Shows the call" : "Opens the panel")
    }
}

private extension CompactSlot {
    var isCall: Bool {
        if case .call = self { return true }
        return false
    }
}

/// What the leading slot draws, given the slot and nothing else.
///
/// Lifted out of `NotchCompactLeadingView` so the state gallery draws the
/// glyphs that ship rather than a copy of them. Everything here is a value in;
/// the closures keep the face and the artwork read lazily — only the branch
/// that draws them reads them, exactly as before the split.
struct CompactLeadingGlyph: View {
    let slot: CompactSlot
    var ambient: () -> BloubFace.Ambient
    var artworkURL: () -> URL?

    var body: some View {
        Group {
            switch slot {
            case .completionTick:
                // A session just finished: acknowledged passively, the island
                // never expands for completions.
                //
                // On THIS side, because it is an agent event. It used to pulse
                // in the trailing slot, where the media wave lives — so
                // finishing a session briefly replaced the music indicator with
                // a green tick, and read as something having happened to your
                // music. Agent news belongs on the agent side.
                //
                // The cloud itself, green and happy, rather than a ✓ — the
                // owner's gallery walk (2026-10-05). Same size as the agent
                // lamp it stands in for, so finishing changes the cloud's
                // colour and face, not its place. It hops on arrival
                // (`BloubFace.celebrates`), and still APPEARS with reduced
                // motion — a completion pulse is the island's product contract.
                bloub(for: slot, width: 17, height: 15)
                    .transition(.opacity)
            case .agentLamp(let attention, let working):
                // The bloub, tinted with the colour the chamber lamp carried.
                //
                // It replaced `AgentLampView`, which is still in the tree and
                // still the icon's own shape — worth knowing before reverting,
                // because that identity (icon, menu bar, glyph: one object in
                // three sizes) was the lamp's whole argument, and this trades it
                // for a face. Kept deliberately: the expression is a channel the
                // lamp did not have, and the tint means nothing was given up to
                // get it.
                //
                // The face does NOT distinguish the gate — attention and plain
                // work are both `.attentive`, matching
                // `BloubExpression(for:)`. The tint is what turns amber, and
                // restating urgency in a cuter channel is how the loud one gets
                // ignored.
                // Asleep when sessions exist but none is working, and quieted.
                //
                // The lamp said this with a stroke at 0.26 opacity — mostly
                // outline, so "here, idle" murmured. A solid tinted cloud at full
                // strength shouts it instead, which is how a notch with nothing
                // happening in it came to look busy. The fill is the loudest
                // thing this glyph owns, so it is what has to give.
                //
                // `working` now drives the expression as well as the blink, which
                // is the distinction the lamp made with motion alone.
                bloub(for: .agentLamp(attention: attention, working: working),
                      width: 17, height: 15)
            case .artwork:
                ArtworkView(url: artworkURL(), size: 15)
            case .meetingIcon:
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.needs)
            case .idle:
                // The island at rest.
                //
                // **Sized to be SEEN, after the first version was not.** A 5pt
                // dot at 45% opacity is, against a black island fused to a black
                // camera housing, indistinguishable from nothing — and "nothing"
                // is the exact thing this rung exists to stop, so a resting
                // state nobody can see is the bug with extra steps.
                //
                // Still the quietest thing in the ladder: no colour, no motion,
                // and any driver above takes the slot outright. It is a sign the
                // app is running and a target to aim at, not a notification.
                // Asleep rather than a chevron, and tinted to the chevron's own
                // colour rather than left on the adaptive body.
                //
                // That is not fussiness: this rung is documented as the quietest
                // thing in the ladder, and the adaptive body is near-white in
                // dark, so a bloub wearing it was a bright blob where a dim
                // arrow used to be — louder than the amber lamp two rungs up,
                // which inverts the whole ladder. `Theme.textSecondary` at 0.9
                // is value-identical to the glyph it replaces, so this is a
                // change of shape and not of volume.
                //
                // It still obeys both of this rung's rules: no colour (a grey,
                // never an accent) and no motion (`animated` left off, so the
                // resting island never blinks at you). The larger filled area is
                // the one thing it does spend, and it is spent on the problem
                // the rung exists for — a resting state nobody can see was
                // reported as a crash four times.
                bloub(for: .idle, width: 15, height: 13)
            default:
                EmptyView()
            }
        }
        // Something needs you: a Nudge — a few gentle beats, then the amber
        // cloud simply stays. A loop would turn the island into wallpaper.
        .nudge(while: needsYou)
    }

    private var needsYou: Bool {
        switch slot {
        case .agentLamp(let attention, _): attention
        case .attentionDot: true
        default: false
        }
    }

    /// One face for both rungs, so the resting island and the agent lamp cannot
    /// drift apart — they were two separate sets of ternaries before, which is
    /// how the resting one ended up unable to say anything at all.
    private func bloub(for slot: CompactSlot, width: CGFloat, height: CGFloat) -> some View {
        let face = BloubFace.resolve(slot: slot, ambient: ambient())
        return BloubView(expression: face.expression,
                         motion: face.motion,
                         tint: face.tint.color)
            .frame(width: width, height: height)
            .opacity(face.isDimmed ? 0.6 : 1)
            // A finished guide or an agent's ✓. Mostly squash: the cloud sits
            // against the top of the screen, so there is little room to rise.
            .bloubHop(when: face.celebrates, lift: 2, onAppear: true)
    }
}

/// What the trailing slot draws, given the slot and nothing else — see
/// `CompactLeadingGlyph` for why it is its own view.
struct CompactTrailingGlyph: View {
    let slot: CompactSlot
    /// The glance event's start, read only by the countdown branch.
    var meetingStart: () -> Date?
    /// Read only by the wave branch: these move many times a second.
    var waveLevels: () -> [Double]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            switch slot {
            #if AIRLOCK_GUIDE
            case .guide(let state):
                GuideCompactTrailing(state: state)
            #else
            case .guide:
                EmptyView()
            #endif
            case .attentionDot:
                Circle()
                    .fill(Theme.needs)
                    .frame(width: 8, height: 8)
                    .shadow(color: Theme.needs.opacity(0.7), radius: 4)
            case .meetingCountdown:
                // The amber countdown is the glance hint. Its window is
                // `CalendarWidgetModel.glanceEvent` — from ten minutes BEFORE
                // the start to five minutes AFTER it, so fifteen minutes, not
                // ten, and it re-arms for each successive event. This said
                // "≤10m" for a long time and that figure was quoted into a
                // compact-island ladder argument (see `CompactIsland`, where the
                // battery/meeting order was reversed once the real width was
                // worked out). Hence the count runs to "now" and stops there:
                // past the start there are no minutes left to show, but the
                // slot is still lit for another five.
                if let start = meetingStart() {
                    TimelineView(.periodic(from: .now, by: 30)) { context in
                        let mins = max(0, Int(start.timeIntervalSince(context.date) / 60))
                        Text(mins == 0 ? "now" : "\(mins)m")
                            // `fixed`, not `chrome`: the kit hard-clips the
                            // compact island to the physical notch height, so
                            // text that grows here is cut off by the window
                            // rather than reflowing.
                            .font(Theme.fixed(11, .bold))
                            .foregroundStyle(Theme.needs)
                            .monospacedDigit()
                    }
                }
            case .wave:
                // Playing music reads as the wave. This used to hand the slot to
                // album art whenever an agent session existed, which sounds like
                // a richer choice and in practice meant anyone actually using the
                // app never saw the wave — sessions are the normal state here,
                // not the exception. Art identifies a track; the wave says
                // something is playing, and that is what a 16pt slot beside a
                // camera housing can usefully say.
                MediaWaveView(color: Theme.textSecondary, animated: true,
                              levels: waveLevels())
                    .scaleEffect(0.8)
            case let .outputRoute(_, _, level, muted):
                // The widest thing the island ever draws, and for two seconds
                // only — see `CompactIsland.routeAcknowledgement`. That budget
                // is what makes covering somebody's menu-bar extras acceptable,
                // so it buys a glyph plus a short bar and NOT a percentage: a
                // number is wider, it repeats the expanded card, and nobody
                // reads one in two seconds. The percentage is in the
                // accessibility label, where width costs nothing.
                HStack(spacing: 3) {
                    // The glyph says WHICH device, because the name is spoken
                    // and never drawn here — so this is the only thing on
                    // screen that distinguishes "moved to the display" from
                    // "moved to the earbuds". It comes from the transport
                    // CoreAudio reports (`AudioOutputDevice.Transport`) and
                    // never from words in the device's name, which anyone can
                    // change. Muted overrides it; see `outputRouteSymbol`.
                    Image(systemName: slot.outputRouteSymbol ?? "speaker.wave.2.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Theme.textSecondary)
                    // Muted draws an EMPTY bar, never "0%" — the level under a
                    // mute is what you come back to, not what you are hearing.
                    // No bar at all for a device with no software volume
                    // (HDMI, many DACs): a bar that can never move is a lie.
                    if muted {
                        OutputLevelBar(level: 0)
                    } else if let level {
                        OutputLevelBar(level: level)
                    }
                }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            case .batteryCritical:
                // STATIC. A blinking or breathing battery would be a new
                // perpetual animation, which is exactly what Reduce Motion asks
                // us not to add — and the colour is already the alarm.
                //
                // Glyph only, minutes in the label: this dwells for fifteen to
                // twenty-five minutes over the menu bar, so it must stay
                // narrower than the two-second acknowledgement above. The
                // widest rung being the shortest-lived one is the rule, not a
                // coincidence.
                Image(systemName: "battery.25")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.danger)
            case .keepAwakeStopped:
                // The cup and the word for what happened to it, for thirty
                // seconds. It was the cup and a battery glyph: two pictures,
                // no words, and at a glance the same cup as "keeping awake".
                // "off" is the news; why (the battery level) is in the spoken
                // label and the open notch's line. About the battery glyph's
                // width, so the slot costs the menu bar nothing more. Grey like
                // the cup: it is news, not something waiting on you.
                HStack(spacing: 3) {
                    KeepAwakeCup()
                    Text(CompactSlot.keepAwakeStoppedWord)
                        .font(Theme.fixed(11, .semibold))  // see the countdown above
                        .foregroundStyle(Theme.textSecondary)
                }
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            case .usageNotice(let notice):
                // A gauge and how full, for thirty seconds — see
                // `Notice.compactLabel`. Which window is in the spoken label
                // and the open island's tiles. Claude's colour for the
                // warning, because it is about Claude and is not something
                // waiting on an answer; grey for the reset.
                HStack(spacing: 3) {
                    switch notice {
                    case .nearLimit:
                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(.system(size: 10, weight: .semibold))
                    case .reset:
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 9, weight: .bold))
                    }
                    if let label = notice.compactLabel {
                        Text(label)
                            .font(Theme.fixed(11, .semibold))  // see the countdown above
                            .monospacedDigit()
                    }
                }
                .foregroundStyle({
                    if case .nearLimit = notice { return Theme.claudeCoral }
                    return Theme.textSecondary
                }())
                .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            case .keepingAwake:
                // A passenger, drawn in the grey of the wave above it — see
                // `KeepAwakeCup` for the colour and why it is its own view.
                KeepAwakeCup()
            case .call(let call):
                CallPill(call: call)
                    .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
            case let .shelfCount(count):
                // The lowest rung, drawn like it: this never summoned the
                // island, it is only filling a slot something else opened.
                HStack(spacing: 2) {
                    Image(systemName: "tray.fill")
                        .font(.system(size: 9, weight: .semibold))
                    Text("\(count)")
                        .font(Theme.fixed(11, .semibold))  // see the countdown above
                        .monospacedDigit()
                }
                .foregroundStyle(Theme.textTertiary)
            default:
                EmptyView()
            }
        }
    }
}
/// The keep-awake rung: the rail's own cup, small and grey.
///
/// Its own view rather than three lines in the trailing switch so that
/// `AwakeCupSnapshot` draws the glyph that ships, not a copy of it.
///
/// **The rail's symbol, never a second spelling of it.** Read off
/// `SystemControlsModel.Control.awake`, so the island and the button that lit
/// it cannot drift into two different cups.
///
/// **Grey, and the wave's grey.** Keep-awake is true rather than urgent — the
/// category `Theme.resting` is documented for — but `resting` is a shade
/// brighter than the wave one rung up, and a rung drawn louder than the rung
/// above it inverts the ladder; the idle rung's bloub did exactly that once.
/// (The rung above was the session count until 2026-09-30, in this same grey;
/// see `CompactIsland.trailing` for why it left.) Cool rather than warm on
/// purpose: a coffee-coloured cup would edge toward `Theme.needs`, and amber on
/// this island means something is waiting on you. Not the rail's lit blue
/// either — on the island blue is the mark and a working agent, and a cup in it
/// would read as one of those.
///
/// A filled cup is solid where the wave is five thin bars. That is the idle
/// rung's trade again, made on purpose: area spent on being recognised at a
/// glance — the whole job of a sign for a state macOS keeps out of the menu
/// bar — and the volume held down where it counts, in the colour, with no
/// motion at all.
struct KeepAwakeCup: View {
    var body: some View {
        Image(systemName: SystemControlsModel.Control.awake.symbol)
            // The size the route glyph uses, a point under the battery's: the
            // saucer makes this symbol wider than it is tall, and width is what
            // this slot pays for in somebody else's menu-bar extras.
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}

/// How loud the new output is, in sixteen points and no characters.
///
/// A bar rather than a percentage because the compact island is a floating panel
/// OVER the menu bar: on a 14-inch the system's own status items begin
/// immediately right of the cutout, so every point this draws is a point of
/// somebody else's chrome covered up. Glyph plus "40%" measured about 2.5× the
/// island's previous widest content; glyph plus this bar is about half that.
private struct OutputLevelBar: View {
    /// 0…1. Clamped rather than trusted — CoreAudio volumes are floats from
    /// hardware, and a bar wider than its track would draw outside the island.
    let level: Float

    private static let width: CGFloat = 16
    private static let height: CGFloat = 3

    var body: some View {
        Capsule()
            .fill(Theme.textSecondary.opacity(0.25))
            .frame(width: Self.width, height: Self.height)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(Theme.textSecondary)
                    .frame(width: Self.width * CGFloat(min(max(level, 0), 1)),
                           height: Self.height)
            }
    }
}

/// Applies a label only when the slot has one — see the trailing slot's note.
/// Setting an empty label instead would silence the element it was meant to fix.
private struct SlotLabel: ViewModifier {
    let label: String?
    init(_ label: String?) { self.label = label }

    @ViewBuilder func body(content: Content) -> some View {
        if let label { content.accessibilityLabel(label) } else { content }
    }
}

/// Shown when the selected tab has nothing to render.
///
/// Says which kind of empty it is, because the two need opposite advice: with
/// every widget switched off the fix is in settings, whereas with them on and
/// simply idle there is nothing to fix and being told to go configure something
/// would be wrong. The whole block is the target, not just the pill — the point
/// is that a blank panel should be the easiest thing in the app to act on.
struct EmptyTabView: View {
    let anyEnabled: Bool
    var onOpenSettings: () -> Void

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: anyEnabled ? "moon.zzz" : "square.grid.2x2")
                .font(.system(size: 19, weight: .light))
                .foregroundStyle(Theme.textTertiary)
            Text(anyEnabled ? "Nothing playing, nothing scheduled." : "No widgets turned on here.")
                .font(Theme.chrome(12, .medium))
                .foregroundStyle(Theme.textSecondary)
            Text(anyEnabled ? "Manage widgets" : "Add widgets")
                .font(Theme.chrome(11, .semibold))
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 1))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpenSettings)
        .clickable()
        .help("Open settings")
        // The only route out of a blank panel. The whole block is the target
        // for the pointer, so it has to be the whole element here too.
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Opens settings")
        .accessibilityAction { onOpenSettings() }
    }
}

/// The call rung: the calling app's logo and how long the call has run, both in
/// the grey of every other compact glyph (the owner, 2026-10-07: "maybe all in
/// grey"; the timer was the microphone-in-use green until then). The logo
/// says which app (`CallGlyph`); the phone glyph stands in for an app it has
/// no logo for.
///
/// **The logo is grey, like every other glyph in the compact island** (the
/// owner, 2026-10-06: "smaller, and grey, same as the rest of the icons"). In
/// colour it was the loudest thing in the menu bar; the logo's shape still
/// says which app, and a ticking timer says it is live.
///
/// The timer is its own `TimelineView`, ticking once a second only while a call
/// is on screen — never the island's clock, which would redraw everything.
struct CallPill: View {
    let call: OngoingCall

    var body: some View {
        HStack(spacing: 3) {
            switch CallGlyph.kind(for: call) {
            case .logo(let name):
                if let logo = CallGlyph.image(name) {
                    // 11 is the height the cup and tray glyphs beside it draw at.
                    Image(nsImage: logo)
                        .renderingMode(.template)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 11, height: 11)
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    symbol("phone.fill")
                }
            case .symbol(let name):
                symbol(name)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(call.elapsedLabel(at: context.date))
                    .font(Theme.fixed(11, .semibold))  // see the meeting countdown
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func symbol(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(Theme.textSecondary)
    }
}
