import AgentHUDCore
import Foundation

@MainActor
final class AgentHUDService {
    static let shared = AgentHUDService()

    let store: UsageStore
    private var observation: UsageChangeObservation?

    private init() {
        let defaults = UserDefaults(suiteName: "com.boringnotch.agenthud") ?? .standard
        let settings = SettingsStore(defaults: defaults)
        L10n.setLanguage(settings.settings.language)
        let ledger = UsageLedger.open()
        let provider = RetainedUsageProvider(
            provider: CombinedUsageProvider.standard(ledger: ledger),
            cacheURL: AppSupport.directory.appendingPathComponent("last-usage-report.json")
        )
        store = UsageStore(provider: provider, settings: settings)
        store.ledger = ledger
        if let report = provider.initialReport {
            store.replace(report: report)
        }
    }

    func start() {
        observation = store.observeChanges { [weak self] _ in
            self?.enableDetectedRows()
        }
        enableDetectedRows()
        if let executable = Bundle.main.executableURL {
            SessionObservers.configure(executable: executable, enabled: true, includePermissionHooks: false)
        }
        store.start()
    }

    func stop() {
        observation?.cancel()
        observation = nil
        store.stop()
    }

    private func enableDetectedRows() {
        let detected = Set(store.report?.discoveredAgents.filter(\.connected).map(\.id) ?? [])
        store.settings.updateAgents { agents in
            agents.map { detected.contains($0.id) ? $0.with(enabled: true) : $0 }
        }
    }
}

enum AgentHUDHookCommand {
    static func runIfNeeded() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { return }
        guard arguments[1] == "--completion-hook" || arguments[1] == "--attention-hook" else { return }

        let data: Data
        do {
            var input = Data()
            while let chunk = try FileHandle.standardInput.read(upToCount: 64 * 1024), !chunk.isEmpty {
                input.append(chunk)
                if input.count > 1024 * 1024 { break }
            }
            data = input
        } catch {
            exit(0)
        }

        switch arguments[1] {
        case "--completion-hook":
            guard let source = CompletionHooks.Source(rawValue: arguments[2]) else { return }
            try? CompletionHooks.record(source: source, data: data)
            print(source == .antigravity ? #"{"decision":"stop"}"# : "{}")
            exit(0)
        case "--attention-hook":
            guard let source = AttentionHooks.Source(rawValue: arguments[2]) else { return }
            try? AttentionHooks.record(source: source, data: data)
            print("{}")
            exit(0)
        default:
            return
        }
    }
}
