import AgentHUDCore
import AgentHUDDesktop
import Combine
import Foundation
import SwiftUI

@MainActor
final class AgentHUDService: ObservableObject {
    static let shared = AgentHUDService()

    let store: UsageStore
    @Published private(set) var notice: AgentHUDNotice?
    @Published private(set) var noticePhase: AgentHUDNoticePhase = .hidden
    private var events = IslandEventTracker()
    private var queuedNotices: [AgentHUDNotice] = []
    private var noticeTask: Task<Void, Never>?
    private var noticeHovered = false

    private init() {
        let defaults = UserDefaults(suiteName: "theboringteam.dihud.agenthud") ?? .standard
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
        observeChanges({ [weak self] in
            _ = self?.store.report
            _ = self?.store.settings.agents
            _ = self?.store.settings.settings.disabledLiveStatusSources
        }, onChange: { [weak self] in
            self?.enableDetectedRows()
            self?.checkEvents()
        })
        enableDetectedRows()
        checkEvents()
        PermissionRequests.shared.holdTime = TimeInterval(store.settings.settings.approvalWaitMinutes * 60)
        PermissionRequests.shared.start()
        if let executable = Bundle.main.executableURL {
            SessionObservers.configure(executable: executable, enabled: true)
        }
        prepareCompletionDirectories()
        store.start()
    }

    func stop() {
        noticeTask?.cancel()
        queuedNotices.removeAll()
        noticePhase = .hidden
        notice = nil
        noticeHovered = false
        PermissionRequests.shared.stop()
        store.stop()
    }

    private func checkEvents() {
        guard !store.isPaused, store.lastError == nil, let report = store.report else { return }
        let update = events.update(report: report, agents: store.settings.agents,
                                   now: Date(), settings: store.settings.settings)
        for alert in update.quotaAlerts where alert.kind == .exhaustion {
            let used = Int((100 - alert.snapshot.remainingPct).rounded())
            let detail: String
            if alert.snapshot.remainingPct <= 0 {
                detail = "额度已耗尽"
            } else if let remaining = alert.timeToExhaust {
                detail = "预计 \(Countdown.compact(max(60, ceil(remaining / 60) * 60))) 后耗尽 · 已用 \(used)%"
            } else {
                detail = "额度即将耗尽 · 已用 \(used)%"
            }
            show(AgentHUDNotice(title: alert.agent.vendorName,
                                detail: detail,
                                symbol: "exclamationmark.circle.fill"))
        }
        for completion in update.completions {
            show(AgentHUDNotice(title: completion.vendor,
                                detail: completion.task.isEmpty ? "任务已完成" : "任务已完成 · \(completion.task)",
                                symbol: "checkmark.circle.fill", completion: completion))
        }
    }

    func holdNotice(_ hovered: Bool) {
        noticeHovered = hovered
        guard noticePhase == .visible else { return }
        scheduleNoticeExpiry()
    }

    func dismissNotice() {
        guard notice != nil, noticePhase == .visible else { return }
        noticeTask?.cancel()
        // Fade the fixed-width content before the surface starts closing through it.
        withAnimation(.easeOut(duration: 0.12), completionCriteria: .removed) {
            noticePhase = .fading
        } completion: { [weak self] in
            guard let self, self.noticePhase == .fading else { return }
            withAnimation(.smooth(duration: 0.36), completionCriteria: .removed) {
                self.noticePhase = .dismissing
            } completion: { [weak self] in
                guard let self, self.noticePhase == .dismissing else { return }
                self.noticePhase = .hidden
                self.notice = nil
                if !self.queuedNotices.isEmpty { self.show(self.queuedNotices.removeFirst()) }
            }
        }
    }

    private func show(_ value: AgentHUDNotice) {
        guard notice == nil else {
            queuedNotices.append(value)
            return
        }
        // Expand the surface before revealing content at its final width.
        withAnimation(.smooth(duration: 0.38), completionCriteria: .removed) {
            notice = value
            noticePhase = .appearing
        } completion: { [weak self] in
            guard let self, self.noticePhase == .appearing else { return }
            withAnimation(.easeOut(duration: 0.18)) {
                self.noticePhase = .visible
            }
            self.scheduleNoticeExpiry()
        }
        NotificationCenter.default.post(name: .agentHUDNoticePresented, object: nil)
    }

    private func scheduleNoticeExpiry() {
        noticeTask?.cancel()
        guard notice != nil, noticePhase == .visible, !noticeHovered else { return }
        noticeTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(4)) } catch { return }
            guard let self, !self.noticeHovered else { return }
            self.dismissNotice()
        }
    }

    private func enableDetectedRows() {
        let detected = Set(store.report?.discoveredAgents.filter(\.connected).map(\.id) ?? [])
        store.settings.updateAgents { agents in
            agents.map { detected.contains($0.id) ? $0.with(enabled: true) : $0 }
        }
    }

    private func prepareCompletionDirectories() {
        for source in CompletionHooks.Source.allCases where CompletionHooks.isInstalled(source) {
            let directory = CompletionHooks.directory.appendingPathComponent(source.rawValue)
            do {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700]
                )
            } catch {
                NSLog("[AgentHUD] Completion directory setup failed for %@: %@",
                      source.rawValue, error.localizedDescription)
            }
        }
    }
}

struct AgentHUDNotice {
    let title: String
    let detail: String
    let symbol: String
    var completion: SessionCompletion? = nil
}

enum AgentHUDNoticePhase {
    case hidden
    case appearing
    case visible
    case fading
    case dismissing
}

enum AgentHUDHookCommand {
    static func runIfNeeded() {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { return }
        if arguments[1] == "--permission-hook" {
            guard let source = PermissionHooks.Source(rawValue: arguments[2]) else { exit(0) }
            PermissionHookClient.run(source: source)
            exit(0)
        }
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
