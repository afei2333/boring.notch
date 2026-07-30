//
//  StockManager.swift
//  boringNotch
//
//  Stocks tab backend: owns the lifecycle of the bundled stock_bridge.py
//  sidecar (spawned via the non-sandboxed XPC helper, same pattern as mimo),
//  polls its localhost JSON API for quotes + intraday timeshare, and runs the
//  alert engine (change%, price cross, intraday reversal) against the
//  user's watchlist. Alerts surface on the closed notch via sneak peek.
//

import Combine
import Defaults
import Foundation
import SwiftUI

// MARK: - Models

/// One quote as served by stock_bridge.py /quotes.
struct StockQuote: Codable, Identifiable, Equatable {
    struct RTPoint: Codable, Equatable {
        let t: String   // "HH:MM"
        let p: Double
    }

    /// US 盘前/盘后 quote; bridge sends it only during that session, and then
    /// `rt` carries the ext-session timeshare instead of the regular one.
    struct ExtQuote: Codable, Equatable {
        let label: String       // "盘前" / "盘后"
        let price: Double
        let changePct: Double?  // vs the session's base close, already in %
        let base: Double?       // sparkline baseline (pre: 昨收, after: 今收)
    }

    let symbol: String
    var name: String? = nil
    var cur: Double? = nil
    var open: Double? = nil
    var high: Double? = nil
    var low: Double? = nil
    var lastClose: Double? = nil
    var volume: Double? = nil
    var turnover: Double? = nil
    var high52w: Double? = nil
    var low52w: Double? = nil
    var marketCap: Double? = nil
    var pe: Double? = nil
    var time: String? = nil
    var rt: [RTPoint]? = nil
    var ext: ExtQuote? = nil

    var id: String { symbol }

    var changePct: Double? {
        guard let cur, let lastClose, lastClose > 0 else { return nil }
        return (cur - lastClose) / lastClose * 100
    }

    var displayName: String { name ?? symbol }

    /// Trading-session segments as minute-of-day ranges (lunch break excluded),
    /// matching whichever session `rt` currently carries. Lets the sparkline
    /// fill proportionally to session progress instead of stretching full-width.
    var sessionSegments: [(start: Int, end: Int)] {
        if let ext { return ext.label == "盘前" ? [(240, 570)] : [(960, 1200)] }
        // 日韩 quotes carry 北京时间 timestamps (= 当地 -1h) from every source:
        // 东京 09:00–15:30 含午休, 首尔 09:00–15:30 无午休.
        if symbol.hasPrefix("JP.") { return [(480, 630), (690, 870)] }
        if symbol.hasPrefix("KR.") { return [(480, 870)] }
        return switch StockMarket.of(symbol) {
        case .hk: [(570, 720), (780, 960)]
        case .cn: [(570, 690), (780, 900)]
        default:  [(570, 960)]
        }
    }
}

enum StockMarket: String, CaseIterable, Identifiable {
    case all = "总"
    case us = "美"
    case hk = "港"
    case cn = "A"

    var id: String { rawValue }

    static func of(_ symbol: String) -> StockMarket {
        switch symbol.prefix(while: { $0 != "." }).uppercased() {
        case "US": .us
        case "HK": .hk
        case "SH", "SZ": .cn
        default: .all
        }
    }

    /// Default tab by wall clock: HK during 港/A 竞价+盘中 (北京 9:15–16:10),
    /// US during its 盘前/盘中/盘后 (纽约 4:00–20:00), otherwise 总.
    /// ponytail: ignores holidays — a wrong tab on a holiday is harmless.
    static var current: StockMarket {
        func minuteOfDay(in tz: String) -> (weekday: Int, minute: Int) {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: tz)!
            let c = cal.dateComponents([.weekday, .hour, .minute], from: .now)
            return (c.weekday!, c.hour! * 60 + c.minute!)
        }
        let cn = minuteOfDay(in: "Asia/Shanghai")
        if (2...6).contains(cn.weekday), (555...970).contains(cn.minute) { return .hk }
        let ny = minuteOfDay(in: "America/New_York")
        if (2...6).contains(ny.weekday), (240..<1200).contains(ny.minute) { return .us }
        return .all
    }
}

/// A watchlist entry. Alert thresholds live in the shared template
/// (Defaults.stockAlert*); per symbol only an on/off switch.
struct WatchedStock: Codable, Hashable, Defaults.Serializable {
    var symbol: String
    var alertsEnabled = true

    init(symbol: String, alertsEnabled: Bool = true) {
        self.symbol = symbol
        self.alertsEnabled = alertsEnabled
    }

    // Tolerant decode so watchlists saved by the old per-symbol-threshold
    // format load instead of wiping the list.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        symbol = try container.decode(String.self, forKey: .symbol)
        alertsEnabled = try container.decodeIfPresent(Bool.self, forKey: .alertsEnabled) ?? true
    }
}

struct StockSearchResult: Codable, Identifiable, Equatable {
    let symbol: String
    let name: String
    var id: String { symbol }
}

struct FiredAlert: Identifiable, Equatable, Codable, Defaults.Serializable {
    var id = UUID()
    let symbol: String
    let message: String
    let date: Date
}

// MARK: - Manager

@MainActor
final class StockManager: ObservableObject {
    static let shared = StockManager()

    enum BridgeState: Equatable {
        case stopped
        case starting
        case ready(port: Int)
        case failed(String)
    }

    @Published private(set) var state: BridgeState = .stopped
    @Published private(set) var quotes: [String: StockQuote] = [:]
    @Published private(set) var bridgeError: String?
    @Published private(set) var firedAlerts: [FiredAlert] = Defaults[.stockAlertHistory]
        .filter { $0.date > .now.addingTimeInterval(-86400) } {
        didSet { Defaults[.stockAlertHistory] = firedAlerts }
    }
    @Published private(set) var unreadAlertCount = 0

    @Published var watchlist: [WatchedStock] = Defaults[.stockWatchlist] {
        didSet {
            Defaults[.stockWatchlist] = watchlist
            Task { await pushWatchlist() }
        }
    }

    private var pid: Int?
    private var port: Int?
    private var startTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    // Ladder triggers: per key, each threshold multiple fires at most once per
    // trading day — crossing 1x alerts, then only 2x, 3x… alert again. A value
    // oscillating around an already-fired rung never re-alerts (no 跌1%→回升→
    // 再跌1% spam); the next alert needs one more full threshold step.
    private var firedLevels: [String: (day: String, level: Int)] = [:]

    private static let pidDefaultsKey = "stockBridgePID"
    private static let helperServiceName = "theboringteam.boringnotch.BoringNotchXPCHelper"

    private init() {}

    private var baseURL: URL? {
        guard case .ready(let port) = state else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Quotes ordered like the watchlist, filtered by market.
    func orderedQuotes(market: StockMarket) -> [StockQuote] {
        watchlist
            .filter { market == .all || StockMarket.of($0.symbol) == market }
            .map { quotes[$0.symbol] ?? StockQuote(symbol: $0.symbol) }
    }

    // MARK: Lifecycle

    /// Kill a bridge orphaned by a crash / force quit, then start fresh.
    func reapStaleBridge() {
        let stale = UserDefaults.standard.integer(forKey: Self.pidDefaultsKey)
        guard stale > 0 else { return }
        Task {
            _ = await XPCHelperClient.shared.stopStockBridge(pid: stale)
            UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
        }
    }

    func start() {
        switch state {
        case .starting, .ready: return
        default: break
        }
        state = .starting
        bridgeError = nil
        startTask?.cancel()
        startTask = Task { await performStart() }
    }

    private func performStart() async {
        guard let script = Bundle.main.url(forResource: "stock_bridge", withExtension: "py") else {
            state = .failed("stock_bridge.py missing from app bundle")
            return
        }
        let result = await XPCHelperClient.shared.startStockBridge(
            scriptPath: script.path, pythonPath: Defaults[.stockPythonPath],
            openDPort: Defaults[.futuOpenDPort])

        guard result.port > 0 else {
            state = .failed(result.error ?? "unknown error")
            NSLog("❌ stock bridge failed to start: \(result.error ?? "?")")
            return
        }

        pid = result.pid
        port = result.port
        UserDefaults.standard.set(result.pid, forKey: Self.pidDefaultsKey)
        state = .ready(port: result.port)
        NSLog("✅ stock bridge ready on 127.0.0.1:\(result.port) (pid \(result.pid))")

        await pushWatchlist()
        startPolling()
    }

    func stop() async {
        startTask?.cancel()
        pollTask?.cancel()
        pollTask = nil
        if let pid {
            _ = await XPCHelperClient.shared.stopStockBridge(pid: pid)
        }
        UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
        pid = nil
        port = nil
        state = .stopped
    }

    /// Best-effort synchronous stop for app termination (mirrors MimoDaemonManager).
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
        proxy?.stopStockBridge(pid: pid) { _ in
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 1.5)

        connection.invalidate()
        UserDefaults.standard.removeObject(forKey: Self.pidDefaultsKey)
    }

    // MARK: Watchlist

    /// Returns false when the input doesn't normalize to a plausible Futu code
    /// (e.g. a stock NAME typed before search results arrived) — such an entry
    /// would retry subscribe forever and pin a "代码格式不正确" error banner.
    @discardableResult
    func addSymbol(_ raw: String) -> Bool {
        let symbol = normalize(raw)
        guard symbol.range(of: #"^(US|HK|SH|SZ|JP|KR)\.[A-Z0-9]{1,10}$"#, options: .regularExpression) != nil else {
            return false
        }
        guard !watchlist.contains(where: { $0.symbol == symbol }) else { return true }
        watchlist.append(WatchedStock(symbol: symbol))
        if case .ready = state {} else { start() }
        return true
    }

    func removeSymbol(_ symbol: String) {
        watchlist.removeAll { $0.symbol == symbol }
        quotes.removeValue(forKey: symbol)
    }

    /// Symbol-keyed (not index-captured): SwiftUI can re-evaluate a stale
    /// Binding after the row was removed, so lookup must happen per-access.
    func binding(for symbol: String) -> Binding<WatchedStock>? {
        guard watchlist.contains(where: { $0.symbol == symbol }) else { return nil }
        return Binding(
            get: {
                StockManager.shared.watchlist.first { $0.symbol == symbol }
                    ?? WatchedStock(symbol: symbol)
            },
            set: { newValue in
                if let index = StockManager.shared.watchlist.firstIndex(where: { $0.symbol == symbol }) {
                    StockManager.shared.watchlist[index] = newValue
                }
            }
        )
    }

    /// "hk.700" → "HK.00700" (Futu wants 5 digits); bare "AAPL" → "US.AAPL";
    /// Yahoo-style suffix codes ("7709.HK", "600519.SS") → Futu prefix format.
    private func normalize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !trimmed.isEmpty else { return "" }
        let symbol = trimmed.contains(".") ? trimmed : "US.\(trimmed)"
        var parts = symbol.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return symbol }
        if parts[0].first?.isNumber == true {
            let market: String? = switch parts[1] {
            case "HK": "HK"
            case "SS", "SH": "SH"
            case "SZ": "SZ"
            default: nil
            }
            if let market { parts = [market, parts[0]] }
        }
        if parts[0] == "HK", parts[1].allSatisfy(\.isNumber), parts[1].count < 5 {
            parts[1] = String(repeating: "0", count: 5 - parts[1].count) + parts[1]
        }
        return parts.joined(separator: ".")
    }

    private func pushWatchlist() async {
        guard let baseURL, !watchlist.isEmpty else { return }
        var request = URLRequest(url: baseURL.appendingPathComponent("watch"))
        request.httpMethod = "POST"
        request.httpBody = try? JSONEncoder().encode(["symbols": watchlist.map(\.symbol)])
        _ = try? await URLSession.shared.data(for: request)
    }

    // MARK: Polling

    private struct QuotesResponse: Codable {
        let ok: Bool
        let error: String?
        let quotes: [StockQuote]
    }

    private struct SnapshotResponse: Codable {
        let ok: Bool
        let error: String?
        let quote: StockQuote?
    }

    private func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func poll() async {
        guard let baseURL, !watchlist.isEmpty else { return }
        do {
            let (data, _) = try await URLSession.shared.data(from: baseURL.appendingPathComponent("quotes"))
            let response = try JSONDecoder().decode(QuotesResponse.self, from: data)
            bridgeError = response.error
            for quote in response.quotes {
                quotes[quote.symbol] = quote
            }
            checkAlerts()
        } catch {
            bridgeError = "bridge unreachable: \(error.localizedDescription)"
        }
    }

    private struct SearchResponse: Codable {
        let loading: Bool
        let results: [StockSearchResult]
    }

    /// Code/name search against the bridge's cached Futu universe.
    /// `loading` is true while the bridge is still downloading the lists (~30s
    /// after the first search) — partial results may already be returned.
    func search(_ query: String) async -> (results: [StockSearchResult], loading: Bool) {
        guard let baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("search"), resolvingAgainstBaseURL: false)
        else { return ([], false) }
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SearchResponse.self, from: data)
        else { return ([], false) }
        return (response.results, response.loading)
    }

    /// Fresh snapshot for the detail page (52w, PE, market cap).
    func fetchSnapshot(_ symbol: String) async -> StockQuote? {
        guard let baseURL,
              var components = URLComponents(url: baseURL.appendingPathComponent("snapshot"), resolvingAgainstBaseURL: false)
        else { return quotes[symbol] }
        components.queryItems = [URLQueryItem(name: "symbol", value: symbol)]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let response = try? JSONDecoder().decode(SnapshotResponse.self, from: data),
              let quote = response.quote
        else { return quotes[symbol] }
        quotes[symbol] = quote
        return quote
    }

    // MARK: Alerts

    func markAlertsRead() {
        unreadAlertCount = 0
    }

    func clearAlertHistory() {
        firedAlerts = []
        unreadAlertCount = 0
    }

    private func checkAlerts() {
        // Drop alerts older than 24h (also filtered at load in the initializer).
        let cutoff = Date.now.addingTimeInterval(-86400)
        if firedAlerts.last.map({ $0.date <= cutoff }) == true {
            firedAlerts.removeAll { $0.date <= cutoff }
        }
        let changeThreshold = Defaults[.stockAlertChangePct]
        let reversalThreshold = Defaults[.stockAlertReversalPct]
        for watched in watchlist where watched.alertsEnabled {
            guard let quote = quotes[watched.symbol], let cur = quote.cur else { continue }
            let name = quote.displayName
            // Exchange-local trading day; resets the ladder across sessions
            // (local midnight would reset mid-session for US stocks).
            let day = String((quote.time ?? "").prefix(10))

            if let threshold = changeThreshold, let pct = quote.changePct {
                edge(key: "chg|\(watched.symbol)", value: abs(pct), threshold: threshold,
                     day: day, symbol: watched.symbol,
                     message: "\(name) \(pct >= 0 ? "涨" : "跌")幅 \(Self.pct(pct))")
            }

            if let threshold = changeThreshold, let ext = quote.ext, let pct = ext.changePct {
                edge(key: "extchg|\(watched.symbol)|\(ext.label)", value: abs(pct), threshold: threshold,
                     day: day, symbol: watched.symbol,
                     message: "\(name) \(ext.label)\(pct >= 0 ? "涨" : "跌")幅 \(Self.pct(pct))")
            }

            if let threshold = reversalThreshold, let lastClose = quote.lastClose {
                let now = Self.nowChange(quote.changePct)
                if let high = quote.high, high > lastClose, high > 0 {
                    edge(key: "revDown|\(watched.symbol)", value: (high - cur) / high * 100,
                         threshold: threshold, day: day, symbol: watched.symbol,
                         message: "\(name) 冲高回落 \(Self.pct((high - cur) / high * 100, signed: false))，\(now)")
                }
                if let low = quote.low, low < lastClose, low > 0 {
                    edge(key: "revUp|\(watched.symbol)", value: (cur - low) / low * 100,
                         threshold: threshold, day: day, symbol: watched.symbol,
                         message: "\(name) 探底回升 \(Self.pct((cur - low) / low * 100, signed: false))，\(now)")
                }
            }
        }
    }

    private func edge(key: String, value: Double, threshold: Double, day: String,
                      symbol: String, message: @autoclosure () -> String) {
        guard threshold > 0 else { return }
        let level = Int(value / threshold)
        // Monotonic day: only a strictly LATER day resets the ladder. quote.time
        // can flip between sources (60s snapshot vs push, or be briefly empty on
        // a partial push) — an equal/older/empty day must never reset, or the
        // same alert refires on every poll while the sources alternate.
        let stored = firedLevels[key]
        let prev = stored.map { day > $0.day ? 0 : $0.level } ?? 0
        guard level > prev else { return }
        firedLevels[key] = (max(day, stored?.day ?? ""), level)
        fire(symbol: symbol, message: message())
    }

    private func fire(symbol: String, message: String) {
        firedAlerts.insert(FiredAlert(symbol: symbol, message: message, date: .now), at: 0)
        if firedAlerts.count > 50 { firedAlerts.removeLast() }
        unreadAlertCount += 1

        let explicit = Defaults[.stockAlertExplicit]
        BoringViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .stockAlert, duration: Defaults[.stockAlertDuration],
            value: CGFloat(unreadAlertCount),
            message: explicit ? message : "")
        NSLog("📈 stock alert: \(message)")
    }

    // MARK: Formatting helpers (shared with the view)

    static func price(_ value: Double?) -> String {
        guard let value else { return "–" }
        return String(format: value < 10 ? "%.3f" : "%.2f", value)
    }

    /// "现涨 1.23%" / "现跌 1.23%" / "现平" — or a hint when the quote has no
    /// day change (missing lastClose, e.g. a partial push before the snapshot).
    static func nowChange(_ pct: Double?) -> String {
        guard let pct else { return "现涨跌幅暂无数据" }
        if pct == 0 { return "现平" }
        return "现\(pct > 0 ? "涨" : "跌") \(Self.pct(abs(pct), signed: false))"
    }

    static func pct(_ value: Double?, signed: Bool = true) -> String {
        guard let value else { return "–" }
        return String(format: signed ? "%+.2f%%" : "%.2f%%", value)
    }

    /// 1.23亿 / 5,432万 style for volume, turnover, market cap.
    static func bigNumber(_ value: Double?) -> String {
        guard let value else { return "–" }
        switch abs(value) {
        case 1e12...: return String(format: "%.2f万亿", value / 1e12)
        case 1e8...: return String(format: "%.2f亿", value / 1e8)
        case 1e4...: return String(format: "%.2f万", value / 1e4)
        default: return String(format: "%.0f", value)
        }
    }
}
