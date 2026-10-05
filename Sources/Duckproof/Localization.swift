import Foundation

/// Localized string, looked up by its English text in Localizable.strings (fr.lproj, …).
/// SwiftUI string literals are localized automatically; this is for everything built in code.
func L(_ english: String, _ args: CVarArg...) -> String {
    let format = Bundle.main.localizedString(forKey: english, value: english, table: nil)
    return args.isEmpty ? format : String(format: format, arguments: args)
}
