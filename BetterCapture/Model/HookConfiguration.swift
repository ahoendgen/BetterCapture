//
//  HookConfiguration.swift
//  BetterCapture
//
//  Data model for post-recording hooks.
//

import Foundation

/// A single hook command to execute after recording stops.
struct HookEntry: Codable, Identifiable {
    var id = UUID()
    var command: String
    var isEnabled: Bool = true
}

/// Configuration for post-recording hook execution.
struct HookConfiguration: Codable {
    var hooks: [HookEntry] = []
    var stopOnError: Bool = true
    var timeoutSeconds: Int = 300
}
