//
//  BoringNotchXPCHelper.swift
//  BoringNotchXPCHelper
//
//  Created by Alexander on 2025-11-16.
//

import Foundation
import ApplicationServices
import IOKit
import CoreGraphics
import Darwin

/// Thread-safe one-shot wrapper around an XPC reply block. An XPC reply must be
/// called exactly once; the daemon launch path can race (port parsed / process
/// exited / timeout), so we funnel every outcome through this.
private final class MimoStartReply {
    private let lock = NSLock()
    private var fulfilled = false
    private let block: (Int, Int, String?) -> Void
    init(_ block: @escaping (Int, Int, String?) -> Void) { self.block = block }
    func fulfill(port: Int, pid: Int, error: String?) {
        lock.lock(); defer { lock.unlock() }
        if fulfilled { return }
        fulfilled = true
        block(port, pid, error)
    }
}

class BoringNotchXPCHelper: NSObject, BoringNotchXPCHelperProtocol {
    
    @objc func isAccessibilityAuthorized(with reply: @escaping (Bool) -> Void) {
        reply(AXIsProcessTrusted())
    }

    @objc func requestAccessibilityAuthorization() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    @objc func ensureAccessibilityAuthorization(_ promptIfNeeded: Bool, with reply: @escaping (Bool) -> Void) {
        if AXIsProcessTrusted() {
            reply(true)
            return
        }

        if promptIfNeeded {
            requestAccessibilityAuthorization()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            reply(AXIsProcessTrusted())
        }
    }
    
    private class KeyboardBrightnessClient {
        private static let keyboardID: UInt64 = 1
        private var clientInstance: NSObject?
        private let getSelector = NSSelectorFromString("brightnessForKeyboard:")
        private let setSelector = NSSelectorFromString("setBrightness:forKeyboard:")

        init() {
            var loaded = false
            let bundlePaths = [
                "/System/Library/PrivateFrameworks/CoreBrightness.framework",
                "/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness"
            ]
            for path in bundlePaths where !loaded {
                if let bundle = Bundle(path: path) {
                    loaded = bundle.load()
                }
            }
            if loaded, let cls = NSClassFromString("KeyboardBrightnessClient") as? NSObject.Type {
                clientInstance = cls.init()
            }
        }

        var isAvailable: Bool { clientInstance != nil }

        func currentBrightness() -> Float? {
            guard let clientInstance,
                  let fn: BrightnessGetter = methodIMP(on: clientInstance, selector: getSelector, as: BrightnessGetter.self)
            else { return nil }
            return fn(clientInstance, getSelector, Self.keyboardID)
        }

        func setBrightness(_ value: Float) -> Bool {
            guard let clientInstance,
                  let fn: BrightnessSetter = methodIMP(on: clientInstance, selector: setSelector, as: BrightnessSetter.self)
            else { return false }
            return fn(clientInstance, setSelector, value, Self.keyboardID).boolValue
        }

        private typealias BrightnessGetter = @convention(c) (NSObject, Selector, UInt64) -> Float
        private typealias BrightnessSetter = @convention(c) (NSObject, Selector, Float, UInt64) -> ObjCBool

        private func methodIMP<T>(on object: NSObject, selector: Selector, as type: T.Type) -> T? {
            guard let cls = object_getClass(object),
                  let method = class_getInstanceMethod(cls, selector)
            else { return nil }
            let imp = method_getImplementation(method)
            return unsafeBitCast(imp, to: type)
        }
    }

    private static let keyboardClient = KeyboardBrightnessClient()

    @objc func isKeyboardBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.isAvailable)
    }

    @objc func currentKeyboardBrightness(with reply: @escaping (NSNumber?) -> Void) {
        reply(Self.keyboardClient.currentBrightness().map { NSNumber(value: $0) })
    }

    @objc func setKeyboardBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        reply(Self.keyboardClient.setBrightness(value))
    }
    // MARK: - Screen Brightness (moved from client app into helper)

    @objc func isScreenBrightnessAvailable(with reply: @escaping (Bool) -> Void) {
        var b: Float = 0
        reply(displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) || ioServiceFor(displayID: CGMainDisplayID()) != nil)
    }

    @objc func currentScreenBrightness(with reply: @escaping (NSNumber?) -> Void) {
        var b: Float = 0
        if displayServicesGetBrightness(displayID: CGMainDisplayID(), out: &b) {
            reply(NSNumber(value: b))
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            var level: Float = 0
            if IODisplayGetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, &level) == kIOReturnSuccess {
                IOObjectRelease(io)
                reply(NSNumber(value: level))
                return
            }
            IOObjectRelease(io)
        }
        reply(nil)
    }

    @objc func setScreenBrightness(_ value: Float, with reply: @escaping (Bool) -> Void) {
        let clamped = max(0, min(1, value))
        if displayServicesSetBrightness(displayID: CGMainDisplayID(), value: clamped) {
            reply(true)
            return
        }
        if let io = ioServiceFor(displayID: CGMainDisplayID()) {
            let ok = IODisplaySetFloatParameter(io, 0, kIODisplayBrightnessKey as CFString, clamped) == kIOReturnSuccess
            IOObjectRelease(io)
            reply(ok)
            return
        }
        reply(false)
    }

    // MARK: - Private helpers for DisplayServices / IOKit access
    private func displayServicesGetBrightness(displayID: CGDirectDisplayID, out: inout Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesGetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        var tmp: Float = 0
        let r = fn(displayID, &tmp)
        if r == 0 { out = tmp; return true }
        return false
    }

    private func displayServicesSetBrightness(displayID: CGDirectDisplayID, value: Float) -> Bool {
        guard let sym = dlsym(DisplayServicesHandle.handle, "DisplayServicesSetBrightness") else { return false }
        typealias Fn = @convention(c) (CGDirectDisplayID, Float) -> Int32
        let fn = unsafeBitCast(sym, to: Fn.self)
        return fn(displayID, value) == 0
    }

    private func ioServiceFor(displayID: CGDirectDisplayID) -> io_service_t? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IODisplayConnect"), &iterator) == kIOReturnSuccess else { return nil }
        defer { IOObjectRelease(iterator) }

        while case let service = IOIteratorNext(iterator), service != 0 {
            let info = IODisplayCreateInfoDictionary(service, 0).takeRetainedValue() as NSDictionary
            if let vendorID = info[kDisplayVendorID] as? UInt32,
               let productID = info[kDisplayProductID] as? UInt32,
               vendorID == CGDisplayVendorNumber(displayID),
               productID == CGDisplayModelNumber(displayID) {
                return service
            }
            IOObjectRelease(service)
        }
        return nil
    }

    // MARK: - Helper handle for private framework
    private enum DisplayServicesHandle {
        static let handle: UnsafeMutableRawPointer? = {
            let paths = [
                "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
                "/System/Library/PrivateFrameworks/DisplayServices.framework/Versions/Current/DisplayServices"
            ]
            for p in paths {
                if let h = dlopen(p, RTLD_LAZY) { return h }
            }
            return nil
        }()
    }

    // MARK: - mimo (mimocode) headless daemon

    private static let mimoLock = NSLock()
    private static var mimoProcesses: [Int: Process] = [:]

    private static var mimoBinaryPath: String {
        // The helper is not sandboxed, so NSHomeDirectory() is the real home.
        NSHomeDirectory() + "/.mimocode/bin/mimo"
    }

    private func executablePath(forPID pid: Int) -> String? {
        guard pid > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    /// Only ever signal a pid we can confirm is actually the mimo binary, so a
    /// recycled/reused pid can't make us kill an unrelated process.
    private func isMimoProcess(_ pid: Int) -> Bool {
        executablePath(forPID: pid)?.hasSuffix("/.mimocode/bin/mimo") ?? false
    }

    @objc func startMimoDaemon(workingDirectory: String, with reply: @escaping (Int, Int, String?) -> Void) {
        let binaryPath = Self.mimoBinaryPath
        guard FileManager.default.isExecutableFile(atPath: binaryPath) else {
            reply(0, 0, "mimo binary not found at \(binaryPath)")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve", "--port", "0", "--hostname", "127.0.0.1", "--print-logs"]
        process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory.isEmpty ? NSHomeDirectory() : workingDirectory)

        var environment = ProcessInfo.processInfo.environment
        let binDir = (binaryPath as NSString).deletingLastPathComponent
        environment["PATH"] = binDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        process.environment = environment

        let errPipe = Pipe()
        let outPipe = Pipe()
        process.standardError = errPipe
        process.standardOutput = outPipe

        let replyOnce = MimoStartReply(reply)

        process.terminationHandler = { proc in
            let exited = Int(proc.processIdentifier)
            replyOnce.fulfill(port: 0, pid: 0, error: "mimo serve exited (status \(proc.terminationStatus)) before reporting a port")
            Self.mimoLock.lock()
            Self.mimoProcesses.removeValue(forKey: exited)
            Self.mimoLock.unlock()
        }

        do {
            try process.run()
        } catch {
            replyOnce.fulfill(port: 0, pid: 0, error: "failed to launch mimo: \(error.localizedDescription)")
            return
        }

        let pid = Int(process.processIdentifier)
        Self.mimoLock.lock()
        Self.mimoProcesses[pid] = process
        Self.mimoLock.unlock()

        // Scan BOTH stdout and stderr for "listening on http://127.0.0.1:PORT"
        // (we don't assume which stream the banner lands on), then keep draining
        // so a full pipe buffer can never block the daemon.
        errPipe.fileHandleForReading.readabilityHandler = portScanningHandler(pid: pid, replyOnce: replyOnce)
        outPipe.fileHandleForReading.readabilityHandler = portScanningHandler(pid: pid, replyOnce: replyOnce)

        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            replyOnce.fulfill(port: 0, pid: pid, error: "timed out waiting for mimo to report a port")
        }
    }

    @objc func stopMimoDaemon(pid: Int, with reply: @escaping (Bool) -> Void) {
        Self.mimoLock.lock()
        let tracked = Self.mimoProcesses.removeValue(forKey: pid)
        Self.mimoLock.unlock()

        if let tracked, tracked.isRunning {
            tracked.terminate()
            reply(true)
            return
        }
        // Helper may have been recycled since the spawn; verify identity then signal.
        guard isMimoProcess(pid) else { reply(false); return }
        reply(kill(Int32(pid), SIGTERM) == 0)
    }

    @objc func mimoDaemonStatus(pid: Int, with reply: @escaping (Bool) -> Void) {
        reply(isMimoProcess(pid))
    }

    /// Returns a fresh readability handler (with its own accumulation buffer) that
    /// scans a pipe for the daemon's listening port, fulfills the reply once found,
    /// then degrades to a pure drain.
    private func portScanningHandler(pid: Int, replyOnce: MimoStartReply) -> (FileHandle) -> Void {
        var buffer = Data()
        return { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            buffer.append(chunk)
            if buffer.count > 65_536 { buffer.removeFirst(buffer.count - 65_536) }
            if let text = String(data: buffer, encoding: .utf8), let port = Self.parsePort(from: text) {
                replyOnce.fulfill(port: port, pid: pid, error: nil)
                handle.readabilityHandler = { drained in _ = drained.availableData }
            }
        }
    }

    private static func parsePort(from text: String) -> Int? {
        guard let regex = try? NSRegularExpression(pattern: #"127\.0\.0\.1:(\d{2,5})"#) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let portRange = Range(match.range(at: 1), in: text) else { return nil }
        return Int(text[portRange])
    }
}
