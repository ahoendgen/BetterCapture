//
//  SuperCaptureApp.swift
//  SuperCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import SwiftUI

@main
struct SuperCaptureApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var viewModel = RecorderViewModel()
    @State private var updaterService = UpdaterService()
    @State private var loginItemService = LoginItemService()
    @State private var hasRequestedPermissions = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .task {
                    guard !hasRequestedPermissions else { return }
                    hasRequestedPermissions = true
                    appDelegate.viewModel = viewModel
                    await viewModel.requestPermissionsOnLaunch()
                }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: viewModel.settings, updaterService: updaterService, loginItemService: loginItemService, transcriptionService: viewModel.transcriptionService, globalShortcut: viewModel.globalShortcut)
        }

        Window("Hooks", id: "hooks-editor") {
            HookSettingsView(hookStore: viewModel.hookStore)
        }
        .defaultLaunchBehavior(.suppressed)
        .defaultSize(width: 600, height: 400)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var viewModel: RecorderViewModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Disable automatic window restoration so URL-scheme activation
        // doesn't re-open previously visible windows (e.g. Hooks editor).
        NSWindow.allowsAutomaticWindowTabbing = false
        UserDefaults.standard.set(true, forKey: "NSQuitAlwaysKeepsWindows")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Prevent window restoration when the app is re-activated (e.g. via URL scheme).
        false
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.scheme == "supercapture" else { continue }
            switch url.host {
            case "toggle":
                Task { await viewModel?.toggleRecording() }
            case "start":
                Task { await viewModel?.startRecording() }
            case "stop":
                Task { await viewModel?.stopRecording() }
            default:
                break
            }
        }

        // Close any windows that macOS restored during activation.
        for window in application.windows where window.identifier?.rawValue == "hooks-editor" {
            window.close()
        }
    }
}

/// The label shown in the menu bar (icon or duration timer)
struct MenuBarLabel: View {
    let viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording {
            if viewModel.settings.discreetMenuBar {
                Image(systemName: "microphone")
            } else if let image = timerImage {
                Image(nsImage: image)
            }
        } else {
            Image(systemName: "record.circle")
        }
    }

    /// Renders the formatted duration into an ``NSImage`` with a stable
    /// width derived from the widest possible string for the current format.
    private var timerImage: NSImage? {
        let text = viewModel.formattedDuration

        // Use the widest possible string for the current format to
        // compute a stable size that won't change between ticks.
        let referenceText: String = if viewModel.recordingDuration >= 3600 {
            "0:00:00"
        } else {
            "00:00"
        }

        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
        ]

        let referenceSize = (referenceText as NSString).size(withAttributes: attrs)
        let imageSize = NSSize(width: ceil(referenceSize.width), height: ceil(referenceSize.height))

        let textSize = (text as NSString).size(withAttributes: attrs)
        let origin = NSPoint(
            x: (imageSize.width - textSize.width) / 2,
            y: (imageSize.height - textSize.height) / 2
        )

        let image = NSImage(size: imageSize, flipped: false) { _ in
            (text as NSString).draw(at: origin, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }
}
