//
//  AppWindows.swift
//  SystemInfo
//

import AppKit

/// Brings the app's windows to the front.
///
/// SystemInfo is a menu bar app without a Dock icon, and macOS only activates such an app if the
/// frontmost app agrees. When it doesn't, a newly opened window ends up behind other apps' windows,
/// which looks as if nothing happened. So the window itself is ordered to the front as well.
enum AppWindows {
    static let settingsIdentifier = "Settings"

    /// Activates the app and puts the window whose identifier contains `identifier` in front.
    static func bringToFront(_ identifier: String) {
        NSApplication.shared.activate()
        Task {
            // The window is created shortly after the open request, so look for it a few times.
            for _ in 0..<20 {
                if let window = NSApplication.shared.windows.first(where: {
                    $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains(identifier) == true
                }) {
                    window.makeKeyAndOrderFront(nil)
                    window.orderFrontRegardless()
                    NSApplication.shared.activate()
                    return
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }
}
