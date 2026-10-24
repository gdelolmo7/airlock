import AirlockCore
import SwiftUI

/// A setting that search can find and a link can land on (card Settings 3).
///
/// Each case is one row on one page: its title as search shows it, the words
/// somebody might type for it, and the page it lives on. The row itself wears
/// `.settingsAnchor(_:)`, which is what the page scrolls to and lights up.
///
/// A row that is not on screen when the link lands (a section that only shows
/// in some states) still opens the right page; it just has nothing to scroll
/// to.
enum SettingsAnchor: String, CaseIterable, Identifiable {
    // General
    case launchAtLogin, appLanguage, displays, sounds, updates, crashReports, usageCounts, diagnostics
    // The notch
    case surface, panelWidth, textSize, usageLimits, batteryPercentage
    case widgets, reactiveWave, perAppVolume
    case keepAwakeAgents, keepAwakeCutoff, keepAwakeScreen, keepAwakeShortcut
    case agentsSwitch, calendars, shelf
    // Voice
    case holdToDictate, microphoneInput, language, callNotes, callLanguages, pastCalls, notesOnline,
         tellVoicesApart, knownWords, cleanup, pauseMusic
    // Clipboard
    case clipboardHistory, neverRecorded, clipboardShortcut, autoPaste
    // Agents
    case gateHotkey, promptSound, usageWarning, givingUp, rules
    // Permissions
    case permissionCalendar, permissionMicrophone, permissionInputMonitoring
    case permissionAccessibility, permissionScreenAudio, permissionAutomation
    // Plans
    case plans, licenceKey, checkPlan

    var id: String { rawValue }

    var pane: SettingsPane {
        switch self {
        case .launchAtLogin, .appLanguage, .displays, .sounds, .updates, .crashReports, .usageCounts, .diagnostics: return .general
        case .surface, .panelWidth, .textSize, .usageLimits, .batteryPercentage,
             .widgets, .reactiveWave, .perAppVolume,
             .keepAwakeAgents, .keepAwakeCutoff, .keepAwakeScreen, .keepAwakeShortcut,
             .agentsSwitch, .calendars, .shelf: return .appearance
        case .holdToDictate, .microphoneInput, .language, .callNotes, .callLanguages, .pastCalls,
             .notesOnline, .tellVoicesApart, .knownWords, .cleanup, .pauseMusic: return .voice
        case .clipboardHistory, .neverRecorded, .clipboardShortcut, .autoPaste: return .clipboard
        case .gateHotkey, .promptSound, .usageWarning, .givingUp, .rules: return .agents
        case .permissionCalendar, .permissionMicrophone, .permissionInputMonitoring,
             .permissionAccessibility, .permissionScreenAudio, .permissionAutomation: return .permissions
        case .plans, .licenceKey, .checkPlan: return .license
        }
    }

    var title: String {
        switch self {
        case .launchAtLogin: return String(localized: "Launch at login")
        case .appLanguage: return String(localized: "Airlock's language")
        case .sounds: return String(localized: "Sounds")
        case .displays: return String(localized: "Show on the main display")
        case .updates: return String(localized: "Check for updates automatically")
        case .crashReports: return String(localized: "Send crash reports")
        case .usageCounts: return String(localized: "Share usage counts")
        case .diagnostics: return String(localized: "Health and diagnostics")
        case .surface: return String(localized: "Background")
        case .panelWidth: return String(localized: "How wide the open notch is")
        case .textSize: return String(localized: "Text size")
        case .usageLimits: return String(localized: "Claude usage limits")
        case .batteryPercentage: return String(localized: "Battery percentage")
        case .widgets: return String(localized: "What shows when it's open")
        case .reactiveWave: return String(localized: "Wave follows the audio")
        case .perAppVolume: return String(localized: "Per-app volume")
        case .keepAwakeAgents: return String(localized: "Keep awake while an agent is working")
        case .keepAwakeCutoff: return String(localized: "Keep awake: stop on battery")
        case .keepAwakeScreen: return String(localized: "Keep awake: let the screen turn off")
        case .keepAwakeShortcut: return String(localized: "Keep awake: keyboard shortcut")
        case .agentsSwitch: return String(localized: "AI agents")
        case .calendars: return String(localized: "Calendars")
        case .shelf: return String(localized: "Shelf")
        case .holdToDictate: return String(localized: "Hold a key to dictate")
        case .microphoneInput: return String(localized: "Microphone")
        case .language: return String(localized: "Language")
        case .callNotes: return String(localized: "Call notes")
        case .callLanguages: return String(localized: "Language on calls")
        case .pastCalls: return String(localized: "Past calls")
        case .notesOnline: return String(localized: "Write notes online")
        case .tellVoicesApart: return String(localized: "Tell voices apart")
        case .knownWords: return String(localized: "Words to know")
        case .cleanup: return String(localized: "Tidy up what I said")
        case .pauseMusic: return String(localized: "Pause music while speaking")
        case .clipboardHistory: return String(localized: "Clipboard history")
        case .neverRecorded: return String(localized: "What it never remembers")
        case .clipboardShortcut: return String(localized: "Clipboard shortcut")
        case .autoPaste: return String(localized: "Paste automatically")
        case .gateHotkey: return String(localized: "Answer with a shortcut")
        case .promptSound: return String(localized: "Play a sound when a request arrives")
        case .usageWarning: return String(localized: "Warn near Claude's usage limit")
        case .givingUp: return String(localized: "Hand the question back")
        case .rules: return String(localized: "Rules")
        case .permissionCalendar: return String(localized: "Calendar access")
        case .permissionMicrophone: return String(localized: "Microphone access")
        case .permissionInputMonitoring: return String(localized: "Input Monitoring")
        case .permissionAccessibility: return String(localized: "Accessibility")
        case .permissionScreenAudio: return String(localized: "Screen & System Audio Recording")
        case .permissionAutomation: return String(localized: "Automation")
        case .plans: return String(localized: "Plans")
        case .licenceKey: return String(localized: "Licence key")
        case .checkPlan: return String(localized: "Check my plan now")
        }
    }

    /// The words somebody might type instead of the title.
    var keywords: [String] {
        switch self {
        case .launchAtLogin: return ["startup", "login", "start", "open"]
        case .appLanguage: return ["language", "spanish", "english", "idioma", "español", "inglés", "translate",
                                   "traducir"]
        case .sounds: return ["sound", "audio", "chime", "alert", "mute", "quiet", "volume"]
        case .displays: return ["display", "monitor", "screen", "external", "lid", "main"]
        case .updates: return ["update", "version", "new"]
        case .crashReports: return ["crash", "report", "sentry", "privacy", "bug", "quit"]
        case .usageCounts: return ["usage", "counts", "analytics", "statistics", "stats", "tracking",
                                   "privacy", "posthog", "share", "data"]
        case .diagnostics: return ["log", "report", "debug", "problem", "health"]
        case .surface: return ["background", "glass", "dark", "look", "colour", "color"]
        case .panelWidth: return ["width", "size", "wide", "narrow"]
        case .textSize: return ["font", "bigger", "larger", "smaller", "zoom", "read"]
        case .usageLimits: return ["usage", "limits", "rate", "hours", "weekly", "agents", "claude"]
        case .batteryPercentage: return ["battery", "percent", "top bar"]
        case .widgets: return ["widget", "media", "music", "spotify", "calendar", "system", "cpu",
                               "memory", "repository", "git", "show", "hide"]
        case .reactiveWave: return ["wave", "bars", "audio", "music", "animation"]
        case .perAppVolume: return ["volume", "mixer", "sound", "app", "loud", "quiet"]
        case .keepAwakeAgents: return ["awake", "sleep", "agent", "claude", "codex", "working", "caffeinate"]
        case .keepAwakeCutoff: return ["awake", "sleep", "battery", "caffeinate", "cutoff"]
        case .keepAwakeScreen: return ["awake", "sleep", "screen", "display", "dark"]
        case .keepAwakeShortcut: return ["awake", "sleep", "shortcut", "hotkey", "key"]
        case .agentsSwitch: return ["agents", "claude", "codex", "developer", "hooks", "connect"]
        case .calendars: return ["calendar", "events", "meetings"]
        case .shelf: return ["shelf", "tray", "files", "drop", "folder"]
        case .holdToDictate: return ["dictation", "dictate", "voice", "speech", "talk", "hold", "key"]
        case .microphoneInput: return ["microphone", "mic", "input", "device", "headset"]
        case .language: return ["language", "spanish", "english", "speak"]
        case .callNotes: return ["calls", "meetings", "notes", "transcript", "teams", "facetime", "minutes",
                                 "record"]
        case .callLanguages: return ["language", "calls", "meetings", "notes", "spanish", "english"]
        case .pastCalls: return ["past", "calls", "meetings", "transcript", "history", "open"]
        case .notesOnline: return ["online", "cloud", "internet", "server", "gemini", "better", "notes",
                                   "meetings", "calls", "summary"]
        case .tellVoicesApart: return ["voices", "speakers", "people", "person", "who said", "who spoke",
                                       "participants", "diarization", "meetings", "calls"]
        case .knownWords: return ["words", "names", "spelling", "vocabulary", "transcript", "meetings", "calls"]
        case .cleanup: return ["cleanup", "punctuation", "filler", "tidy"]
        case .pauseMusic: return ["music", "pause", "speaking"]
        case .clipboardHistory: return ["clipboard", "history", "copy", "paste"]
        case .neverRecorded: return ["password", "ignore", "private", "skip", "clipboard"]
        case .clipboardShortcut: return ["shortcut", "hotkey", "clipboard", "key"]
        case .autoPaste: return ["paste", "clipboard"]
        case .gateHotkey: return ["approve", "allow", "shortcut", "hotkey", "request", "key", "answer"]
        case .promptSound: return ["sound", "alert", "notification", "request"]
        case .usageWarning: return ["usage", "limit", "warning", "rate", "weekly", "hours", "reset", "claude"]
        case .givingUp: return ["timeout", "giving up", "wait"]
        case .rules: return ["policy", "rules", "allow", "deny", "block"]
        case .permissionCalendar: return ["calendar", "permission", "privacy"]
        case .permissionMicrophone: return ["microphone", "mic", "permission", "privacy"]
        case .permissionInputMonitoring: return ["keyboard", "keys", "permission", "privacy", "input"]
        case .permissionAccessibility: return ["accessibility", "typing", "permission", "privacy"]
        case .permissionScreenAudio: return ["screen recording", "system audio", "other side", "call", "screenshot",
                                             "record", "permission", "privacy"]
        case .permissionAutomation: return ["automation", "apple events", "permission", "spotify", "music"]
        case .plans: return ["plan", "plans", "plus", "pro", "free", "upgrade", "price", "pricing", "buy",
                             "subscribe", "subscription", "monthly", "yearly"]
        case .licenceKey: return ["license", "licence", "key", "subscription", "purchase", "buy", "trial"]
        case .checkPlan: return ["check", "plan", "paid", "refresh", "subscription", "another mac"]
        }
    }

    /// The same in Spanish. Searched in every app language, like the English
    /// ones, so a word in either finds the row. Accents don't matter.
    var spanishKeywords: [String] {
        switch self {
        case .launchAtLogin: return ["inicio", "arrancar", "abrir", "sesion", "encender"]
        case .appLanguage: return []
        case .sounds: return ["sonido", "audio", "aviso", "alerta", "silencio", "volumen"]
        case .displays: return ["pantalla", "monitor", "externa", "tapa", "principal"]
        case .updates: return ["actualizacion", "actualizar", "version", "nuevo"]
        case .crashReports: return ["fallo", "error", "informe", "privacidad", "cierre"]
        case .usageCounts: return ["uso", "estadisticas", "analitica", "privacidad", "compartir", "datos"]
        case .diagnostics: return ["registro", "informe", "diagnostico", "problema", "salud"]
        case .surface: return ["fondo", "cristal", "oscuro", "aspecto", "color"]
        case .panelWidth: return ["ancho", "anchura", "tamaño", "estrecho"]
        case .textSize: return ["letra", "fuente", "texto", "grande", "pequeño", "zoom", "leer"]
        case .usageLimits: return ["uso", "limites", "horas", "semanal", "agentes", "claude"]
        case .batteryPercentage: return ["bateria", "porcentaje", "barra"]
        case .widgets: return ["widget", "musica", "calendario", "sistema", "memoria", "repositorio",
                               "mostrar", "ocultar"]
        case .reactiveWave: return ["onda", "barras", "audio", "musica", "animacion"]
        case .perAppVolume: return ["volumen", "mezclador", "sonido", "app", "alto", "bajo"]
        case .keepAwakeAgents: return ["despierto", "reposo", "dormir", "agente", "claude", "codex", "trabajando"]
        case .keepAwakeCutoff: return ["despierto", "reposo", "dormir", "bateria", "limite"]
        case .keepAwakeScreen: return ["despierto", "reposo", "pantalla", "apagar"]
        case .keepAwakeShortcut: return ["despierto", "reposo", "atajo", "tecla"]
        case .agentsSwitch: return ["agentes", "claude", "codex", "desarrollador", "conectar"]
        case .calendars: return ["calendario", "eventos", "reuniones"]
        case .shelf: return ["estante", "bandeja", "archivos", "soltar", "carpeta"]
        case .holdToDictate: return ["dictado", "dictar", "voz", "hablar", "mantener", "tecla"]
        case .microphoneInput: return ["microfono", "entrada", "dispositivo", "auriculares", "cascos"]
        case .language: return ["idioma", "español", "ingles", "hablar"]
        case .callNotes: return ["llamadas", "reuniones", "notas", "transcripcion", "acta", "grabar"]
        case .callLanguages: return ["idioma", "llamadas", "reuniones", "notas", "español", "ingles"]
        case .pastCalls: return ["anteriores", "llamadas", "reuniones", "transcripcion", "historial", "abrir"]
        case .notesOnline: return ["online", "nube", "internet", "servidor", "mejores", "notas", "reuniones",
                                   "llamadas", "resumen"]
        case .tellVoicesApart: return ["voces", "personas", "participantes", "quien hablo", "quien dijo",
                                       "reuniones", "llamadas"]
        case .knownWords: return ["palabras", "nombres", "ortografia", "vocabulario", "transcripcion",
                                  "reuniones", "llamadas"]
        case .cleanup: return ["limpiar", "puntuacion", "muletillas", "ordenar"]
        case .pauseMusic: return ["musica", "pausa", "pausar", "hablar"]
        case .clipboardHistory: return ["portapapeles", "historial", "copiar", "pegar"]
        case .neverRecorded: return ["contraseña", "ignorar", "privado", "omitir", "portapapeles"]
        case .clipboardShortcut: return ["atajo", "tecla", "portapapeles"]
        case .autoPaste: return ["pegar", "portapapeles", "automatico"]
        case .gateHotkey: return ["aprobar", "permitir", "atajo", "solicitud", "tecla", "responder"]
        case .promptSound: return ["sonido", "aviso", "notificacion", "solicitud"]
        case .usageWarning: return ["uso", "limite", "aviso", "semanal", "horas", "claude"]
        case .givingUp: return ["tiempo", "espera", "esperar", "devolver"]
        case .rules: return ["politica", "reglas", "permitir", "denegar", "bloquear"]
        case .permissionCalendar: return ["calendario", "permiso", "privacidad"]
        case .permissionMicrophone: return ["microfono", "permiso", "privacidad"]
        case .permissionInputMonitoring: return ["teclado", "teclas", "permiso", "privacidad", "entrada"]
        case .permissionAccessibility: return ["accesibilidad", "escribir", "permiso", "privacidad"]
        case .permissionScreenAudio: return ["grabacion de pantalla", "audio del sistema", "otra parte", "llamada",
                                             "captura", "grabar", "permiso", "privacidad"]
        case .permissionAutomation: return ["automatizacion", "permiso", "spotify", "musica"]
        case .plans: return ["plan", "planes", "plus", "pro", "gratis", "mejorar", "precio", "comprar",
                             "suscribirse", "suscripcion", "mensual", "anual"]
        case .licenceKey: return ["licencia", "clave", "suscripcion", "compra", "comprar", "prueba"]
        case .checkPlan: return ["comprobar", "plan", "pagado", "actualizar", "suscripcion", "otro mac"]
        }
    }

    /// Whether the row exists in the Settings shown now. The call languages and
    /// the way to past calls only while call notes are on (`callNotesOn`), as
    /// on the Voice page. "Write notes online" only with call notes on and
    /// notes online shown (`notesOnlineOn`).
    @MainActor
    func isAvailable(callNotesOn: Bool = SettingsAnchor.callNotesAreOn,
                     notesOnlineOn: Bool = SettingsAnchor.notesOnlineShown) -> Bool {
        switch self {
        // Only a build that could send one shows the switch.
        case .crashReports: return CrashReporter.bundleDSN != nil
        case .usageCounts: return UsageCounts.bundleEndpoint != nil
        case .callLanguages, .pastCalls, .tellVoicesApart, .knownWords: return callNotesOn
        case .notesOnline: return callNotesOn && notesOnlineOn
        default: return true
        }
    }

    /// Read the way the call notes' model reads its switch.
    @MainActor
    static var callNotesAreOn: Bool { MeetingNotesModel.isOn }

    /// "Write notes online" is there only while notes online are switched on,
    /// and for a subscriber: nobody else's notes go online.
    @MainActor
    static var notesOnlineShown: Bool {
        CloudNotesService.shared.isOn && CloudNotesService.shared.plan().limits.writesNotesOnline
    }

    /// Matching settings for the search field, best first.
    @MainActor
    static func search(_ query: String, callNotesOn: Bool = callNotesAreOn,
                       notesOnlineOn: Bool = notesOnlineShown) -> [SettingsAnchor] {
        allCases
            .filter {
                $0.isAvailable(callNotesOn: callNotesOn, notesOnlineOn: notesOnlineOn)
            }
            .compactMap { anchor -> (SettingsAnchor, Int)? in
                SettingsSearch.score(query: query, title: anchor.title,
                                     keywords: anchor.keywords + anchor.spanishKeywords,
                                     page: anchor.pane.title).map { (anchor, $0) }
            }
            // Stable among equals: the order above is page order.
            .enumerated()
            .sorted { $0.element.1 != $1.element.1 ? $0.element.1 > $1.element.1 : $0.offset < $1.offset }
            .map(\.element.0)
    }
}

extension View {
    /// Marks the row a link or a search result for `anchor` lands on: the page
    /// scrolls to it, and it lights up for a moment.
    func settingsAnchor(_ anchor: SettingsAnchor) -> some View {
        modifier(SettingsAnchorHighlight(anchor: anchor))
    }
}

private struct SettingsAnchorHighlight: ViewModifier {
    let anchor: SettingsAnchor
    /// Optional so a pane can be drawn on its own — the state gallery draws
    /// Settings pages without the settings window's model. In that window it
    /// is always there.
    @Environment(SettingsModel.self) private var model: SettingsModel?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .id(anchor)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(model?.highlighted == anchor ? 0.22 : 0))
                    .padding(-6)
                    .animation(Motion.swap.animation(reduceMotion: reduceMotion), value: model?.highlighted)
                    .allowsHitTesting(false)
            }
    }
}
