import Foundation

enum Language: String, CaseIterable, Identifiable, Codable {
    case system, zhHans = "zh-Hans", en
    var id: Self { self }

    var label: String {
        switch self {
        case .system: tr("System")
        case .zhHans: "简体中文"
        case .en: "English"
        }
    }
}

/// English source strings are the keys; each `.lproj/Localizable.strings` translates them.
/// Adding a language means adding one `.lproj` folder and one `Language` case.
enum L10n {
    nonisolated(unsafe) static var bundle = Bundle.main
    nonisolated(unsafe) static var locale = Locale.current

    static func use(_ language: Language) {
        locale = language == .system ? .current : Locale(identifier: language.rawValue)
        bundle = language == .system ? .main
            : Bundle.main.path(forResource: language.rawValue, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    }
}

func tr(_ key: String) -> String { L10n.bundle.localizedString(forKey: key, value: key, table: nil) }
func tr(_ key: String, _ args: CVarArg...) -> String { String(format: tr(key), arguments: args) }
