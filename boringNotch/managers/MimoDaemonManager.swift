//
//  MimoDaemonManager.swift
//  boringNotch
//
//  Owns the lifecycle of the `mimo serve` headless daemon. The main app is
//  sandboxed and cannot exec external binaries, so the spawn is delegated to the
//  non-sandboxed BoringNotchXPCHelper; the app then talks to the daemon directly
//  over localhost HTTP/SSE (allowed by the `network.client` entitlement).
//

import Foundation
import Combine

@MainActor
final class MimoDaemonManager: ObservableObject {
    static let shared = MimoDaemonManager()

    enum State: Equatable {
        case stopped
        case notInstalled
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: State = .stopped

    private(set) var port: Int?
    private(set) var pid: Int?

    private static let pidDefaultsKey = "mimoDaemonPID"
    private static let helperServiceName = "theboringteam.boringnotch.BoringNotchXPCHelper"

    private var startTask: Task<Void, Never>?

    private init() {}

    /// Base URL of the running daemon, or nil if not ready.
    var baseURL: URL? {
        guard let port, isReady else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    var isReady: Bool {
        if case .ready = state { return true }
        return false
    }

    // MARK: - Lifecycle

    /// Kill any daemon left running from a previous app run (crash / force quit).
    /// Safe to call at launch before starting a fresh one.
    func reapStaleDaemon() {
        let stalePID = UserDefaults.standard.integer(forKey: Self.pidDefaultsKey)
        guard stalePID > 0 else { return }
        Task {
            _ = await XPCHelperClient.shared.stopMimoDaemon(pid: stalePID)
            UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
            NSLog("🧹 Reaped stale mimo daemon (pid \(stalePID))")
        }
    }

    func start() {
        switch state {
        case .starting, .ready:
            return
        default:
            break
        }
        state = .starting
        startTask?.cancel()
        startTask = Task { await self.performStart() }
    }

    /// Starts the daemon if needed and resolves once it is ready (or failed).
    @discardableResult
    func ensureRunning() async -> Bool {
        if isReady { return true }
        start()
        while true {
            switch state {
            case .ready:
                return true
            case .failed, .notInstalled, .stopped:
                return false
            case .starting:
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func performStart() async {
        let result = await XPCHelperClient.shared.startMimoDaemon()

        guard result.port > 0 else {
            let message = result.error ?? "unknown error"
            state = message.localizedCaseInsensitiveContains("not found") ? .notInstalled : .failed(message)
            NSLog("❌ mimo daemon failed to start: \(message)")
            return
        }

        port = result.port
        pid = result.pid
        UserDefaults.standard.set(result.pid, forKey: Self.pidDefaultsKey)

        if await waitForHealthy(port: result.port, timeout: 12) {
            state = .ready(port: result.port)
            NSLog("✅ mimo daemon ready on 127.0.0.1:\(result.port) (pid \(result.pid))")
        } else {
            NSLog("❌ mimo daemon did not become healthy on port \(result.port)")
            state = .failed("mimo server did not become healthy")
            await stop()
        }
    }

    private func waitForHealthy(port: Int, timeout: TimeInterval) async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/config") else { return false }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Task.isCancelled { return false }
            var request = URLRequest(url: url)
            request.timeoutInterval = 2
            if let (_, response) = try? await URLSession.shared.data(for: request),
               let http = response as? HTTPURLResponse, http.statusCode == 200 {
                return true
            }
            try? await Task.sleep(for: .milliseconds(400))
        }
        return false
    }

    func stop() async {
        startTask?.cancel()
        if let pid {
            _ = await XPCHelperClient.shared.stopMimoDaemon(pid: pid)
        }
        UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
        port = nil
        pid = nil
        state = .stopped
    }

    /// Best-effort synchronous stop for the app-termination path. Uses a throwaway
    /// XPC connection (whose reply is delivered off the main thread) so blocking the
    /// main thread on the semaphore cannot deadlock. If it times out, the persisted
    /// pid lets the next launch reap the orphan via `reapStaleDaemon()`.
    nonisolated func stopOnTerminate() {
        let pid = UserDefaults.standard.integer(forKey: Self.pidDefaultsKey)
        guard pid > 0 else { return }

        let connection = NSXPCConnection(serviceName: Self.helperServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BoringNotchXPCHelperProtocol.self)
        connection.resume()

        let semaphore = DispatchSemaphore(value: 0)
        let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
            semaphore.signal()
        } as? BoringNotchXPCHelperProtocol
        proxy?.stopMimoDaemon(pid: pid) { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)

        connection.invalidate()
        UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
    }
}
