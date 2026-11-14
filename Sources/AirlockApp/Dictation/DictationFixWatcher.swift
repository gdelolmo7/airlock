import AppKit
import AirlockCore

/// Looks, for a few seconds after a dictation, at the one text box it was
/// typed into, for a word the person fixed by hand (`DictationCorrection`).
///
/// **The privacy line, kept in code.** It starts only after Airlock itself
/// typed, reads only the box that had the focus then, and stops at the first
/// of: `watchesFor` running out, the focus going anywhere else, a fix found,
/// or the next dictation. Password boxes, boxes that can't be read and very
/// long ones are skipped without reading. Nothing it reads is kept or logged:
/// only a learned word leaves it, and only to be offered back to the person.
@MainActor
final class DictationFixWatcher {
    /// Long enough to see a word put right just after it landed.
    static let watchesFor: TimeInterval = 10
    static let looksEvery: TimeInterval = 0.5
    /// Longer than this, the box is left alone: a document, not a field.
    static let longestRead = 20_000

    private var task: Task<Void, Never>?

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Starts watching the box with the focus now, which `typed` was just
    /// typed into. `found` is called at most once.
    func watch(typed: String, found: @escaping @MainActor (DictationCorrection.Learned) -> Void) {
        stop()
        guard DictationWordsStore.learns, TypeService.isTrusted else { return }
        task = Task { @MainActor [weak self] in
            // The last keystrokes take a moment to land in the box.
            try? await Task.sleep(for: .seconds(0.4))
            guard !Task.isCancelled, let element = Self.focusedField(),
                  let before = Self.text(of: element) else { return }
            let words = DictationWordsStore.load()
            var last = before
            let ends = Date().addingTimeInterval(Self.watchesFor)
            while Date() < ends {
                try? await Task.sleep(for: .seconds(Self.looksEvery))
                guard !Task.isCancelled else { return }
                // Focus moved on: whatever is typed now is not a fix of ours.
                guard let now = Self.focusedField(), CFEqual(now, element),
                      let after = Self.text(of: element) else { break }
                guard after != last else { continue }
                last = after
                if let learned = DictationCorrection.find(typed: typed, before: before, after: after,
                                                          words: words,
                                                          isDictionaryWord: DictationWordsStore.isDictionaryWord) {
                    dictationLog("  a fixed word was found after typing")
                    self?.task = nil
                    found(learned)
                    return
                }
            }
            self?.task = nil
        }
    }

    /// The focused element, when it is a text box that isn't a password one.
    static func focusedField() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement // swiftlint:disable:this force_cast
        if let subrole = string(element, kAXSubroleAttribute), subrole == (kAXSecureTextFieldSubrole as String) {
            return nil
        }
        if let role = string(element, kAXRoleAttribute), role == "AXSecureTextField" { return nil }
        return element
    }

    static func text(of element: AXUIElement) -> String? {
        // Asked first where the box can say, so a long document is never read.
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let count = count as? Int, count > longestRead { return nil }
        guard let text = string(element, kAXValueAttribute), text.utf16.count <= longestRead else { return nil }
        return text
    }

    /// Where the cursor is, in UTF-16 units, or nil when the box has a
    /// selection or can't say.
    static func caret(of element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        // swiftlint:disable:next force_cast
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.length == 0, range.location >= 0 else {
            return nil
        }
        return range.location
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }
}
