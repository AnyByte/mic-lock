// MicLock's Control Center toggle (macOS 26+), a WidgetKit extension embedded in MicLock.app.
// The extension is sandboxed; it shares state with the app through the app's own defaults
// domain (temporary-exception.shared-preference entitlement, no App Group, so no developer
// team is needed) and wakes the app with a Darwin notification.
import AppIntents
import Foundation
import notify
import SwiftUI
import WidgetKit

let appDefaults = UserDefaults(suiteName: "org.anybyte.miclock")
let changedNotification = "org.anybyte.miclock.changed"

func lockEnabled() -> Bool { appDefaults?.object(forKey: "enabled") as? Bool ?? true }

struct LockValueProvider: ControlValueProvider {
    var previewValue: Bool { true }
    func currentValue() async throws -> Bool { lockEnabled() }
}

struct SetLockIntent: SetValueIntent {
    static let title: LocalizedStringResource = "Lock Built-in Microphone"
    static let isDiscoverable = false

    @Parameter(title: "Locked")
    var value: Bool

    init() {}

    func perform() async throws -> some IntentResult {
        appDefaults?.set(value, forKey: "enabled")
        appDefaults?.synchronize()
        notify_post(changedNotification)
        return .result()
    }
}

struct MicLockControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "org.anybyte.miclock.control", provider: LockValueProvider()) { isOn in
            ControlWidgetToggle("Built-in Mic", isOn: isOn, action: SetLockIntent()) { on in
                Label(on ? "Locked" : "Unlocked", image: on ? "miclock" : "miclock.open")
            }
            .tint(.orange)
        }
        .displayName("MicLock")
        .description("Keep the MacBook microphone selected.")
    }
}

@main
struct MicLockWidgets: WidgetBundle {
    var body: some Widget { MicLockControl() }
}
