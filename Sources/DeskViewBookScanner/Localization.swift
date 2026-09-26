import Foundation

/// Lokalisierte Strings aus dem Paket-Bundle. `Bundle.main` kennt die Kataloge
/// eines Swift-Package-Targets nicht, darum immer `.module`.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: .module)
}
