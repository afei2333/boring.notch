//
//  BoringNotchXPCHelperProtocol.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation

/// The protocol that this service will vend as its API. This protocol will also need to be visible to the process hosting the service.
@objc protocol BoringNotchXPCHelperProtocol {
    func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void)
    func requestAccessibilityAuthorization()
    func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void)
    // Keyboard backlight / CoreBrightness access (performed by the helper)
    func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // Screen brightness access (performed by the helper)
    func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void)
    func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void)
    func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void)
    // mimo (mimocode) headless daemon — spawned by the helper because the main
    // app is sandboxed and cannot exec external binaries. The app then talks to
    // the daemon over localhost HTTP/SSE.
    func startMimoDaemon(workingDirectory: String, with reply: @escaping (_ port: Int, _ pid: Int, _ errorMessage: String?) -> Void)
    func stopMimoDaemon(pid: Int, with reply: @escaping (_ success: Bool) -> Void)
    func mimoDaemonStatus(pid: Int, with reply: @escaping (_ running: Bool) -> Void)
}

