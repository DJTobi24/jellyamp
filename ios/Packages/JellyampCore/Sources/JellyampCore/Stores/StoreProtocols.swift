import Foundation

/// Settings persistence (UserDefaults on device, dictionary in tests).
public protocol SettingsStoring {
    func loadSettings() -> AppSettings
    func save(_ settings: AppSettings)
}
