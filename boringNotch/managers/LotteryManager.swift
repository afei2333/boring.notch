//
//  LotteryManager.swift
//  boringNotch
//
//  赛博彩票 tab backend: fetches 双色球 (福彩) and 大乐透 (体彩) draw results
//  straight from the official web APIs with URLSession, and settles the user's
//  simulated tickets against them. No sidecar, no helper — both endpoints are
//  plain HTTPS GETs returning JSON, and the app already holds the
//  network.client entitlement.
//
//  Tickets bind to "the first draw newer than the newest draw at purchase
//  time", so settlement stays correct across a week of the app being closed:
//  every unsettled ticket looks up its own 期, backfilling from history when
//  several draws were missed. Nothing polls — refresh() runs when the tab
//  opens and at launch.
//
//  The rules (奖级 mapping, 复式 stake counting, prize math) live in
//  LotteryRules.swift; prize *amounts* always come from the draw itself.
//

import Defaults
import Foundation

extension LotteryTicket: Defaults.Serializable {}

@MainActor
final class LotteryManager: ObservableObject {
    static let shared = LotteryManager()

    /// Newest known draw per game — the binding point for new purchases.
    @Published private(set) var latest: [LotteryGame: LotteryDraw] = [:]
    @Published private(set) var tickets: [LotteryTicket] = Defaults[.lotteryTickets]
    @Published private(set) var refreshing = false
    @Published private(set) var error: String?
    /// Winning tickets already seen in 历史记录 — the badge is winCount − this.
    @Published private(set) var seenWins = Defaults[.lotterySeenWinCount]

    private var lastRefresh: Date?

    private init() {}

    // MARK: Ledger

    var totalCost: Int { tickets.reduce(0) { $0 + $1.cost } }
    var totalPrize: Double { tickets.reduce(0) { $0 + ($1.result?.prize ?? 0) } }
    var net: Double { totalPrize - Double(totalCost) }

    /// 待开奖 first (newest purchase first), then settled by 期号 descending.
    var ordered: [LotteryTicket] {
        tickets.sorted { a, b in
            switch (a.result, b.result) {
            case (nil, nil): a.purchasedAt > b.purchasedAt
            case (nil, _): true
            case (_, nil): false
            case (let x?, let y?): x.drawNum == y.drawNum ? a.purchasedAt > b.purchasedAt
                                                          : x.drawNum > y.drawNum
            }
        }
    }

    /// Main list: only 待开奖. Settled tickets live in 历史记录.
    var pending: [LotteryTicket] { ordered.filter(\.isPending) }
    var history: [LotteryTicket] { ordered.filter { !$0.isPending } }

    private var winCount: Int { tickets.count { ($0.result?.prize ?? 0) > 0 } }

    /// Unread wins — tickets that hit while the user was not looking.
    var unseenWins: Int { max(0, winCount - seenWins) }

    func markHistorySeen() {
        guard unseenWins > 0 else { return }
        seenWins = winCount
        Defaults[.lotterySeenWinCount] = seenWins
    }

    // MARK: Betting

    @discardableResult
    func buy(game: LotteryGame, front: [Int], back: [Int], multiplier: Int, addOn: Bool,
             auto: Bool = false) -> Bool {
        guard let newest = latest[game],
              game.frontRange.contains(front.count), game.backRange.contains(back.count),
              (1...LotteryGame.maxMultiplier).contains(multiplier) else { return false }
        tickets.append(LotteryTicket(game: game, front: front.sorted(), back: back.sorted(),
                                     multiplier: multiplier, addOn: addOn && game.supportsAddOn,
                                     afterDrawNum: newest.num, autoRenew: auto))
        persist()
        return true
    }

    /// 自动续投 开关 — the only way to stop a chain, so it works on any ticket.
    func toggleAuto(_ ticket: LotteryTicket) {
        guard let i = tickets.firstIndex(where: { $0.id == ticket.id }) else { return }
        tickets[i].auto.toggle()
        persist()
    }

    private func persist() { Defaults[.lotteryTickets] = tickets }

    // MARK: Refresh & settlement

    /// Pulls the newest draw of each game and settles whatever it can. Throttled
    /// so re-entering the tab a few times in a row does not re-hit the APIs.
    func refresh(force: Bool = false) async {
        if !force, let last = lastRefresh, Date.now.timeIntervalSince(last) < 300 { return }
        guard !refreshing else { return }
        refreshing = true
        var failure: String?

        for game in LotteryGame.allCases {
            do {
                guard let newest = try await fetch(game, pageSize: 1).first else { continue }
                latest[game] = newest

                // Only reach into history when a pending ticket predates the
                // draw before last. ponytail: window capped at 100 期 (≈8 months
                // of draws) — a ticket left unsettled longer than that stays
                // 待开奖 rather than justifying a paging loop.
                var window = [newest]
                let oldestPending = tickets
                    .filter { $0.game == game && $0.isPending }
                    .map(\.afterDrawNum).min()
                if let oldest = oldestPending, newest.num > oldest + 1 {
                    window = try await fetch(game, pageSize: min(100, newest.num - oldest + 1))
                }
                settle(game: game, using: window)
            } catch {
                failure = "\(game.title)开奖数据获取失败：\(error.localizedDescription)"
            }
        }

        error = failure
        if failure == nil { lastRefresh = .now }
        refreshing = false
    }

    private func settle(game: LotteryGame, using draws: [LotteryDraw]) {
        let byNum = draws.sorted { $0.num < $1.num }
        guard !byNum.isEmpty else { return }
        var changed = false
        // Index walk, not `tickets.indices`: 自动续投 appends the follow-up ticket
        // as each one settles, and that ticket must be settled too — that is how
        // a week of missed draws replays as the chain of 期 the user would have
        // actually played.
        var i = 0
        while i < tickets.count {
            defer { i += 1 }
            guard tickets[i].game == game, tickets[i].isPending,
                  let draw = byNum.first(where: { $0.num > tickets[i].afterDrawNum }) else { continue }
            tickets[i].result = LotteryRules.settle(tickets[i], draw: draw)
            changed = true
            if tickets[i].auto { tickets.append(tickets[i].renewed(after: draw.num)) }
        }
        if changed { persist() }
    }

    // MARK: Official APIs

    private func fetch(_ game: LotteryGame, pageSize: Int) async throws -> [LotteryDraw] {
        switch game {
        case .ssq:
            // Note: no `issueCount` param — with it the API pins the response to a
            // single 期 and ignores pageSize, which breaks history backfill.
            return try LotteryRules.parseSSQ(await get(
                "https://www.cwl.gov.cn/cwl_admin/front/cwlkj/search/kjxx/findDrawNotice"
                    + "?name=ssq&pageNo=1&pageSize=\(pageSize)&systemType=PC",
                referer: "https://www.cwl.gov.cn/"))
        case .dlt:
            return try LotteryRules.parseDLT(await get(
                "https://webapi.sporttery.cn/gateway/lottery/getHistoryPageListV1.qry"
                    + "?gameNo=85&provinceId=0&pageNo=1&pageSize=\(pageSize)&isVerify=1",
                referer: "https://www.lottery.gov.cn/"))
        }
    }

    private func get(_ url: String, referer: String) async throws -> Data {
        var request = URLRequest(url: URL(string: url)!, timeoutInterval: 15)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        request.setValue(referer, forHTTPHeaderField: "Referer")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LotteryError.badResponse
        }
        return data
    }
}
