import Foundation
import UIKit

struct PageTurnSettings: Codable, Equatable {
    var gesture: PageTurnGesture
    /// 0...100 (UI-friendly)
    var confidence: Int
    /// Performance mode: hides chrome + keeps screen awake
    var performanceMode: Bool

    static let `default` = PageTurnSettings(
        gesture: .blink,
        confidence: 60,
        performanceMode: false
    )
}

final class PageTurnSettingsStore {
    static let shared = PageTurnSettingsStore()
    private init() {}

    private let key = "PageTurnSettings.v2"

    func load() -> PageTurnSettings {
        guard
            let data = UserDefaults.standard.data(forKey: key),
            let decoded = try? JSONDecoder().decode(PageTurnSettings.self, from: data)
        else { return .default }
        return decoded
    }

    func save(_ settings: PageTurnSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

extension Notification.Name {
    /// Posted when the app wants the head-tilt system to recalibrate baseline.
    static let requestTiltRecalibration = Notification.Name("requestTiltRecalibration")
}

/// Central place for UI styling
enum MPStyle {
    /// Pick a single accent you like. You can also wire this to Assets later.
    static let accentColor: UIColor = .systemIndigo
}

