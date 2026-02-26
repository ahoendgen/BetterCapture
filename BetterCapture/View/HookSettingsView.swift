//
//  HookSettingsView.swift
//  BetterCapture
//
//  Minimal editor for post-recording hooks.
//

import SwiftUI

/// Window for editing post-recording hook configuration.
struct HookSettingsView: View {
    @Bindable var hookStore: HookStore

    var body: some View {
        VStack(spacing: 0) {
            // Hook list
            List {
                ForEach($hookStore.configuration.hooks) { $hook in
                    HookRow(hook: $hook, onDelete: {
                        hookStore.removeHook(id: hook.id)
                    })
                }
                .onMove { source, destination in
                    hookStore.moveHooks(from: source, to: destination)
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
            .overlay {
                if hookStore.configuration.hooks.isEmpty {
                    ContentUnavailableView(
                        "No Hooks",
                        systemImage: "terminal",
                        description: Text("Add a hook to run commands after each recording.")
                    )
                }
            }

            Divider()

            // Bottom controls
            HStack {
                Button("Add Hook", systemImage: "plus") {
                    hookStore.addHook()
                }

                Spacer()

                Toggle("Stop on Error", isOn: $hookStore.configuration.stopOnError)
                    .onChange(of: hookStore.configuration.stopOnError) { _, _ in
                        hookStore.save()
                    }

                Divider()
                    .frame(height: 16)

                HStack(spacing: 4) {
                    Text("Timeout:")
                    TextField(
                        "seconds",
                        value: $hookStore.configuration.timeoutSeconds,
                        format: .number
                    )
                    .frame(width: 60)
                    .onChange(of: hookStore.configuration.timeoutSeconds) { _, _ in
                        hookStore.save()
                    }
                    Text("s")
                }
            }
            .padding()
        }
        .frame(minWidth: 500, minHeight: 300)
    }
}

// MARK: - Hook Row

/// A single hook entry with command editor and enabled toggle.
struct HookRow: View {
    @Binding var hook: HookEntry
    let onDelete: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Toggle("", isOn: $hook.isEnabled)
                .toggleStyle(.checkbox)
                .labelsHidden()

            TextField("bash command...", text: $hook.command, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .lineLimit(1...3)
                .focused($isFocused)
                .onChange(of: isFocused) { _, focused in
                    if !focused {
                        // Save when field loses focus
                        NotificationCenter.default.post(name: .hookDidChange, object: nil)
                    }
                }

            Button("Remove", systemImage: "trash", role: .destructive, action: onDelete)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Notification

extension Notification.Name {
    static let hookDidChange = Notification.Name("hookDidChange")
}
