import Foundation

/// Os 7 idiomas do app Android, com o mesmo seletor dentro do app.
enum Lang: String, CaseIterable, Identifiable {
    case pt, en, es, fr, it, ru, zh

    var id: String { rawValue }

    var flag: String {
        switch self {
        case .pt: return "🇧🇷"
        case .en: return "🇺🇸"
        case .es: return "🇪🇸"
        case .fr: return "🇫🇷"
        case .it: return "🇮🇹"
        case .ru: return "🇷🇺"
        case .zh: return "🇨🇳"
        }
    }

    var label: String { self == .zh ? "中文" : rawValue.uppercased() }

    var name: String {
        switch self {
        case .pt: return "Português"
        case .en: return "English"
        case .es: return "Español"
        case .fr: return "Français"
        case .it: return "Italiano"
        case .ru: return "Русский"
        case .zh: return "中文"
        }
    }

    var locale: Locale {
        let ids: [Lang: String] = [.pt: "pt-BR", .en: "en-US", .es: "es-ES", .fr: "fr-FR",
                                   .it: "it-IT", .ru: "ru-RU", .zh: "zh-CN"]
        return Locale(identifier: ids[self] ?? "pt-BR")
    }

    /// Idioma salvo, senão o do aparelho, senão português.
    static var initial: Lang {
        if let saved = UserDefaults.standard.string(forKey: "lang"), let lang = Lang(rawValue: saved) { return lang }
        return Lang(rawValue: Locale.preferredLanguages.first.map { String($0.prefix(2)) } ?? "") ?? .pt
    }

    func t(_ key: String, _ params: [String: String] = [:]) -> String {
        var str = TRANSLATIONS[self]?[key] ?? TRANSLATIONS[.pt]?[key] ?? key
        for (k, v) in params { str = str.replacingOccurrences(of: "{\(k)}", with: v) }
        return str
    }
}
