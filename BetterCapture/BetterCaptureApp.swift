//
//  BetterCaptureApp.swift
//  BetterCapture
//
//  Created by Joshua Sattler on 29.01.26.
//

import SwiftUI

@main
struct BetterCaptureApp: App {
    @State private var viewModel = RecorderViewModel()
    @State private var updaterService = UpdaterService()
    @State private var hasRequestedPermissions = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(viewModel: viewModel)
                .task {
                    guard !hasRequestedPermissions else { return }
                    hasRequestedPermissions = true
                    await viewModel.requestPermissionsOnLaunch()
                }
        } label: {
            MenuBarLabel(viewModel: viewModel)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(settings: viewModel.settings, updaterService: updaterService, globalShortcut: viewModel.globalShortcut)
        }

        Window("Hooks", id: "hooks-editor") {
            HookSettingsView(hookStore: viewModel.hookStore)
        }
        .defaultSize(width: 600, height: 400)
    }
}

/// The label shown in the menu bar (icon or duration timer)
struct MenuBarLabel: View {
    let viewModel: RecorderViewModel

    var body: some View {
        if viewModel.isRecording {
            // Render the duration into a fixed-size image so the
            // NSStatusItem never recalculates its width on each tick.
            if let image = timerImage {
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
