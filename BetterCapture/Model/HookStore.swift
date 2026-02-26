//
//  HookStore.swift
//  BetterCapture
//
//  Persists hook configuration as JSON in Application Support.
//

import Foundation
import OSLog

/// Manages loading, saving, and editing of post-recording hook configuration.
@MainActor
@Observable
final class HookStore {

    // MARK: - Properties

    var configuration: HookConfiguration = HookConfiguration()

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "BetterCapture", category: "HookStore")

    // MARK: - File Path

    private static var configDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "BetterCapture")
    }

    private static var configFileURL: URL {
        configDirectory.appending(path: "hooks.json")
    }

    // MARK: - Initialization

    init() {
        load()
    }

    // MARK: - Persistence

    /// Loads the hook configuration from disk. Falls back to empty configuration.
    func load() {
        let url = Self.configFileURL
        guard FileManager.default.fileExists(atPath: url.path()) else {
            logger.info("No hooks.json found, using defaults")
            return
        }

        do {
            let data = try Data(contentsOf: url)
            configuration = try JSONDecoder().decode(HookConfiguration.self, from: data)
            logger.info("Loaded \(self.configuration.hooks.count) hooks from hooks.json")
        } catch {
            logger.error("Failed to load hooks.json: \(error.localizedDescription)")
        }
    }

    /// Saves the current configuration to disk.
    func save() {
        let url = Self.configFileURL
        do {
            try FileManager.default.createDirectory(at: Self.configDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: url, options: .atomic)
            logger.info("Saved \(self.configuration.hooks.count) hooks to hooks.json")
        } catch {
            logger.error("Failed to save hooks.json: \(error.localizedDescription)")
        }
    }

    // MARK: - Editing

    /// Appends a new empty hook entry.
    func addHook() {
        configuration.hooks.append(HookEntry(command: ""))
        save()
    }

    /// Removes the hook with the given ID.
    func removeHook(id: UUID) {
        configuration.hooks.removeAll { $0.id == id }
        save()
    }

    /// Moves hooks for reordering.
    func moveHooks(from source: IndexSet, to destination: Int) {
        configuration.hooks.move(fromOffsets: source, toOffset: destination)
        save()
    }
}
