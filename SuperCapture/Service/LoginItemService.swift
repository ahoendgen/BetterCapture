//
//  LoginItemService.swift
//  SuperCapture
//

import ServiceManagement

/// Wraps `SMAppService.mainApp` to expose login-item state for SwiftUI.
@MainActor
@Observable
final class LoginItemService {

    private(set) var isEnabled = false

    init() {
        refreshStatus()
    }

    func toggle() {
        do {
            if isEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            // register/unregister can fail silently (e.g. user denied in System Settings)
        }
        refreshStatus()
    }

    private func refreshStatus() {
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
