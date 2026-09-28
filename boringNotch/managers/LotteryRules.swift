//
//  LotteryRules.swift
//  boringNotch
//
//  Pure rules for the 赛博彩票 tab: 双色球 / 大乐透 bet shapes, 中奖等级 mapping and
//  combinatorial stake counting for 复式 tickets. No networking, no state — every
//  result here is a pure function of (ticket, draw).
//
//  Prize *amounts* are never hardcoded: both official APIs report the per-stake
//  amount of every 奖级 for every 期 (三等奖以下在大乐透里也是浮动的), so the code
//  only decides *which* 奖级 a combination hits and reads the money from the draw.
//
//  Runnable self-check (validates the 奖级 table against real draw statistics):
//      swiftc -DLOTTERY_CHECK -parse-as-library -Onone \
//          boringNotch/managers/LotteryRules.swift -o /tmp/lc && /tmp/lc
//

import Foundation

// MARK: - Game

enum LotteryGame: String, Codable, CaseIterable, Identifiable {
    case ssq   // 双色球 (福彩)
    case dlt   // 超级大乐透 (体彩)

    var id: String { rawValue }
    var title: String { self == .ssq ? "双色球" : "大乐透" }
    var frontName: String { self == .ssq ? "红球" : "前区" }
    var backName: String { self == .ssq ? "蓝球" : "后区" }
    var frontMax: Int { self == .ssq ? 33 : 35 }
    var backMax: Int { self == .ssq ? 16 : 12 }
    var frontPick: Int { self == .ssq ? 6 : 5 }
    var backPick: Int { self == .ssq ? 1 : 2 }

    /// 复式 selection limits — 双色球 红6–20/蓝1–16, 大乐透 前5–18/后2–12.
    var frontRange: ClosedRange<Int> { self == .ssq ? 6...20 : 5...18 }
    var backRange: ClosedRange<Int> { self == .ssq ? 1...16 : 2...12 }

    /// 双色球 6 个奖等; 大乐透 7 个 — that is what the 体彩 API actually reports,
    /// see the self-check at the bottom of this file for the evidence.
    var levelCount: Int { self == .ssq ? 6 : 7 }

    /// 追加投注 is 大乐透-only: +1 元/注, extra prize on whichever 奖级 the draw
    /// reports a 追加 row for (currently 一、二等奖).
    var supportsAddOn: Bool { self == .dlt }

    static let unitPrice = 2
    static let addOnPrice = 1
    static let maxMultiplier = 99
}

// MARK: - Models

struct LotteryDraw: Codable, Equatable, Identifiable {
    var game: LotteryGame
    var num: Int            // 期号 as a number, for ordering
    var numText: String     // 期号 as printed ("2026092" / "26090")
    var date: String        // "2026-08-11"
    var front: [Int]
    var back: [Int]
    /// 奖级 → 单注基本奖金.
    var prizes: [Int: Double]
    /// 奖级 → 单注追加奖金 (大乐透 only; absent 奖级 pay no 追加).
    var addOnPrizes: [Int: Double]

    var id: String { "\(game.rawValue)-\(num)" }
}

struct LotteryResult: Codable, Equatable {
    var drawNum: Int
    var drawText: String
    var date: String
    var front: [Int]
    var back: [Int]
    /// 奖级 → 中奖注数 (before 倍数).
    var hits: [Int: Int]
    var prize: Double
}

struct LotteryTicket: Codable, Identifiable, Equatable {
    var id = UUID()
    var game: LotteryGame
    var front: [Int]
    var back: [Int]
    var multiplier = 1
    var addOn = false
    /// 期号 of the newest draw at purchase time. The ticket plays the first draw
    /// strictly newer than this — so a rollover to a new year needs no special
    /// casing, and nothing depends on predicting the next 期号 correctly.
    var afterDrawNum: Int
    var purchasedAt = Date.now
    var result: LotteryResult?
    /// 自动续投. Optional on purpose: the synthesized decoder ignores default
    /// values, so a plain `Bool` would fail to decode tickets persisted before
    /// this flag existed. Use `auto`.
    var autoRenew: Bool?

    var auto: Bool {
        get { autoRenew ?? false }
        set { autoRenew = newValue }
    }

    /// The follow-up ticket after this one settles against 期 `drawNum` — same
    /// numbers, same 倍数/追加, bound to the next draw.
    func renewed(after drawNum: Int) -> LotteryTicket {
        LotteryTicket(game: game, front: front, back: back, multiplier: multiplier,
                      addOn: addOn, afterDrawNum: drawNum, autoRenew: true)
    }

    var stakes: Int {
        LotteryRules.comb(front.count, game.frontPick) * LotteryRules.comb(back.count, game.backPick)
    }

    var cost: Int {
        stakes * multiplier * (LotteryGame.unitPrice + (addOn ? LotteryGame.addOnPrice : 0))
    }

    var isPending: Bool { result == nil }
}

// MARK: - Rules

enum LotteryRules {
    static func comb(_ n: Int, _ k: Int) -> Int {
        guard k >= 0, k <= n else { return 0 }
        var r = 1
        for i in 0..<min(k, n - k) { r = r * (n - i) / (i + 1) }
        return r
    }

    /// 奖级 for a single bet that hit `front` front numbers and `back` back
    /// numbers, or nil for a losing bet.
    static func level(_ game: LotteryGame, front: Int, back: Int) -> Int? {
        switch game {
        case .ssq:
            switch (front, back) {
            case (6, 1): 1
            case (6, 0): 2
            case (5, 1): 3
            case (5, 0), (4, 1): 4
            case (4, 0), (3, 1): 5
            case (0...2, 1): 6          // 蓝球中即中，红球 0–2 个
            default: nil
            }
        case .dlt:
            switch (front, back) {
            case (5, 2): 1
            case (5, 1): 2
            case (5, 0), (4, 2): 3
            case (4, 1): 4
            case (4, 0), (3, 2): 5
            case (3, 1), (2, 2): 6
            case (3, 0), (2, 1), (1, 2), (0, 2): 7
            default: nil
            }
        }
    }

    /// 奖级 → 中奖注数 for a (possibly 复式) selection against a draw.
    ///
    /// Closed form instead of enumerating combinations: a 复式 ticket splitting
    /// `hitFront` winning numbers out of `front.count` contains exactly
    /// C(hit, i)·C(miss, pick−i) bets that hit `i` — so a 20-红球 ticket (620160
    /// 注) costs the same handful of multiplications as a 单式 one.
    static func tally(_ game: LotteryGame, front: [Int], back: [Int], draw: LotteryDraw) -> [Int: Int] {
        let winFront = Set(draw.front), winBack = Set(draw.back)
        let hf = front.filter(winFront.contains).count, nf = front.count
        let hb = back.filter(winBack.contains).count, nb = back.count

        var hits: [Int: Int] = [:]
        for i in 0...game.frontPick {
            let fc = comb(hf, i) * comb(nf - hf, game.frontPick - i)
            guard fc > 0 else { continue }
            for j in 0...game.backPick {
                let bc = comb(hb, j) * comb(nb - hb, game.backPick - j)
                guard bc > 0, let lv = level(game, front: i, back: j) else { continue }
                hits[lv, default: 0] += fc * bc
            }
        }
        return hits
    }

    static func settle(_ ticket: LotteryTicket, draw: LotteryDraw) -> LotteryResult {
        let hits = tally(ticket.game, front: ticket.front, back: ticket.back, draw: draw)
        let prize = hits.reduce(0.0) { sum, hit in
            let basic = draw.prizes[hit.key] ?? 0
            let extra = ticket.addOn ? (draw.addOnPrizes[hit.key] ?? 0) : 0
            return sum + Double(hit.value * ticket.multiplier) * (basic + extra)
        }
        return LotteryResult(drawNum: draw.num, drawText: draw.numText, date: draw.date,
                             front: draw.front, back: draw.back, hits: hits, prize: prize)
    }

    /// 机选 一注 (单式).
    static func quickPick(_ game: LotteryGame) -> (front: [Int], back: [Int]) {
        (front: (1...game.frontMax).shuffled().prefix(game.frontPick).sorted(),
         back: (1...game.backMax).shuffled().prefix(game.backPick).sorted())
    }
}

// MARK: - Official API payloads

/// Parsing lives here rather than in the manager so the self-check can run it
/// against recorded payloads without a network round trip.
extension LotteryRules {
    /// Amounts arrive as "155,846" / "-1" / "---" / "" — the last three mean the
    /// 奖级 had no winner this 期, so no per-stake amount was published.
    static func amount(_ text: String) -> Double? {
        guard let value = Double(text.replacingOccurrences(of: ",", with: "")), value >= 0 else {
            return nil
        }
        return value
    }

    /// A 一等奖 with zero winners publishes no per-stake amount, but a simulated
    /// ticket can still hit it. The 奖池 is what a lone winner would draw from,
    /// subject to the 1000 万 单注封顶.
    static func jackpotFallback(pool: String?) -> Double {
        min(10_000_000, pool.flatMap(amount) ?? 10_000_000)
    }

    // MARK: 双色球 (中国福彩)

    private struct SSQPayload: Decodable {
        struct Item: Decodable {
            struct Grade: Decodable { let type: Int; let typemoney: String }
            let code: String
            let date: String
            let red: String
            let blue: String
            let poolmoney: String?
            let prizegrades: [Grade]
        }
        let state: Int
        let result: [Item]?
    }

    static func parseSSQ(_ data: Data) throws -> [LotteryDraw] {
        let payload = try JSONDecoder().decode(SSQPayload.self, from: data)
        guard payload.state == 0, let items = payload.result else { throw LotteryError.badResponse }

        return items.compactMap { item in
            guard let num = Int(item.code) else { return nil }
            var prizes: [Int: Double] = [:]
            for grade in item.prizegrades where (1...LotteryGame.ssq.levelCount).contains(grade.type) {
                if let money = amount(grade.typemoney) { prizes[grade.type] = money }
            }
            if prizes[1] == nil { prizes[1] = jackpotFallback(pool: item.poolmoney) }
            return LotteryDraw(
                game: .ssq, num: num, numText: item.code,
                date: String(item.date.prefix(10)),        // "2026-08-11(二)"
                front: item.red.split(separator: ",").compactMap { Int($0) },
                back: [Int(item.blue) ?? 0],
                prizes: prizes, addOnPrizes: [:])
        }
    }

    // MARK: 超级大乐透 (中国体彩)

    private struct DLTPayload: Decodable {
        struct Item: Decodable {
            struct Level: Decodable { let prizeLevel: String; let stakeAmountFormat: String }
            let lotteryDrawNum: String
            let lotteryDrawTime: String
            let lotteryDrawResult: String
            let poolBalanceAfterdraw: String?
            let prizeLevelList: [Level]
        }
        struct Value: Decodable { let list: [Item] }
        let value: Value
    }

    private static let cnNumerals = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]

    /// "三等奖" → 3, "二等奖(追加)" → (2, 追加).
    private static func parseLevel(_ label: String) -> (level: Int, addOn: Bool)? {
        guard let index = cnNumerals.firstIndex(where: { label.hasPrefix($0) }) else { return nil }
        return (index + 1, label.contains("追加"))
    }

    static func parseDLT(_ data: Data) throws -> [LotteryDraw] {
        let items = try JSONDecoder().decode(DLTPayload.self, from: data).value.list
        let game = LotteryGame.dlt

        return items.compactMap { item in
            guard let num = Int(item.lotteryDrawNum) else { return nil }
            let balls = item.lotteryDrawResult.split(separator: " ").compactMap { Int($0) }
            guard balls.count == game.frontPick + game.backPick else { return nil }

            var prizes: [Int: Double] = [:], addOn: [Int: Double] = [:]
            for row in item.prizeLevelList {
                guard let parsed = parseLevel(row.prizeLevel),
                      let money = amount(row.stakeAmountFormat) else { continue }
                if parsed.addOn { addOn[parsed.level] = money } else { prizes[parsed.level] = money }
            }
            if prizes[1] == nil { prizes[1] = jackpotFallback(pool: item.poolBalanceAfterdraw) }
            // 追加 rows with no winner publish no amount. Every priced row the API
            // does return comes out to exactly 80% of its basic prize, so fill the
            // gaps with that — including 一等奖, whose basic side may itself be the
            // 奖池 fallback above.
            for row in item.prizeLevelList {
                guard let parsed = parseLevel(row.prizeLevel), parsed.addOn,
                      addOn[parsed.level] == nil, let basic = prizes[parsed.level] else { continue }
                addOn[parsed.level] = (basic * 0.8).rounded()
            }

            return LotteryDraw(
                game: .dlt, num: num, numText: item.lotteryDrawNum,
                date: item.lotteryDrawTime,
                front: Array(balls.prefix(game.frontPick)).sorted(),
                back: Array(balls.suffix(game.backPick)).sorted(),
                prizes: prizes, addOnPrizes: addOn)
        }
    }
}

enum LotteryError: LocalizedError {
    case badResponse
    var errorDescription: String? { "接口返回异常" }
}

// MARK: - Self-check

#if LOTTERY_CHECK
@main
enum LotteryCheck {
    /// Combinatorial weight of a 奖级: how many of the game's possible bets land
    /// there. Derived from `LotteryRules.level`, so it tests the real table.
    static func weights(_ g: LotteryGame) -> [Int: Int] {
        var w: [Int: Int] = [:]
        for i in 0...g.frontPick {
            let fc = LotteryRules.comb(g.frontPick, i)
                * LotteryRules.comb(g.frontMax - g.frontPick, g.frontPick - i)
            for j in 0...g.backPick {
                let bc = LotteryRules.comb(g.backPick, j)
                    * LotteryRules.comb(g.backMax - g.backPick, g.backPick - j)
                if let lv = LotteryRules.level(g, front: i, back: j) { w[lv, default: 0] += fc * bc }
            }
        }
        return w
    }

    /// Real 中奖注数 from the official APIs. Ratios between adjacent 奖级 must
    /// track the combinatorial ratios — that is what pins the 奖级 table down,
    /// and it is how the 大乐透 table (7 levels, not the 9 you get from memory)
    /// was derived in the first place. 一、二等奖 are excluded: a couple of dozen
    /// winners is too small a sample to be stable.
    static func checkTable() {
        let cases: [(LotteryGame, String, [Int: Int])] = [
            (.ssq, "2026092", [1: 12, 2: 79, 3: 1317, 4: 64191, 5: 1232442, 6: 9865794]),
            (.dlt, "26090", [1: 2, 2: 93, 3: 1169, 4: 16783, 5: 66157, 6: 818960, 7: 8260921]),
            (.dlt, "26089", [1: 3, 2: 150, 3: 1260, 4: 22077, 5: 86043, 6: 880886, 7: 8760312]),
            (.dlt, "26087", [1: 9, 2: 172, 3: 1692, 4: 22409, 5: 85514, 6: 837692, 7: 8145266]),
        ]
        for (game, issue, observed) in cases {
            let w = weights(game)
            assert(w.count == game.levelCount,
                   "\(game.title): 奖级表有 \(w.count) 级，接口报 \(game.levelCount) 级")
            for lv in 3..<game.levelCount {
                let obs = Double(observed[lv + 1]!) / Double(observed[lv]!)
                let exp = Double(w[lv + 1]!) / Double(w[lv]!)
                let off = abs(obs - exp) / exp
                assert(off < 0.25,
                       "\(game.title) \(issue) 第\(lv)→\(lv+1)等奖注数比 \(obs) 偏离理论 \(exp) 达 \(Int(off * 100))%")
            }
        }
    }

    /// Every bet in a 复式 ticket lands in exactly one bucket, winning or not —
    /// so the tally plus the losing bets must equal the total 注数 (Vandermonde).
    static func checkTally() {
        for game in LotteryGame.allCases {
            let draw = LotteryDraw(game: game, num: 1, numText: "1", date: "",
                                   front: Array(1...game.frontPick),
                                   back: Array(1...game.backPick),
                                   prizes: [:], addOnPrizes: [:])
            for nf in [game.frontPick, game.frontRange.upperBound] {
                for nb in [game.backPick, game.backRange.upperBound] {
                    let front = Array(1...nf), back = Array(1...nb)
                    let total = LotteryRules.comb(nf, game.frontPick) * LotteryRules.comb(nb, game.backPick)
                    var counted = 0
                    for i in 0...game.frontPick {
                        for j in 0...game.backPick {
                            counted += LotteryRules.comb(game.frontPick, i)
                                * LotteryRules.comb(nf - game.frontPick, game.frontPick - i)
                                * LotteryRules.comb(game.backPick, j)
                                * LotteryRules.comb(nb - game.backPick, game.backPick - j)
                        }
                    }
                    assert(counted == total, "\(game.title) \(nf)+\(nb) 组合数 \(counted) ≠ \(total)")
                    let hits = LotteryRules.tally(game, front: front, back: back, draw: draw)
                    assert(hits[1] == 1, "\(game.title) \(nf)+\(nb) 应恰好包含 1 注一等奖")
                    assert(hits.values.reduce(0, +) <= total)
                }
            }
        }
    }

    /// 单式 end to end: exact match pays 一等奖 × 倍数, plus 追加 when bought.
    static func checkSettle() {
        let draw = LotteryDraw(game: .dlt, num: 26090, numText: "26090", date: "2026-08-10",
                               front: [9, 14, 17, 19, 24], back: [2, 9],
                               prizes: [1: 10_000_000, 3: 6666], addOnPrizes: [1: 8_000_000])
        var t = LotteryTicket(game: .dlt, front: [9, 14, 17, 19, 24], back: [2, 9],
                              multiplier: 3, addOn: true, afterDrawNum: 26089)
        assert(t.cost == 9, "3 元/注 × 3 倍 = 9，实得 \(t.cost)")
        assert(LotteryRules.settle(t, draw: draw).prize == 54_000_000)

        t.addOn = false
        assert(t.cost == 6)
        assert(LotteryRules.settle(t, draw: draw).prize == 30_000_000)

        // 自动续投: same bet, bound to the 期 that just settled, still auto.
        let next = t.renewed(after: draw.num)
        assert(next.isPending && next.auto && next.afterDrawNum == draw.num)
        assert(next.front == t.front && next.back == t.back
               && next.multiplier == t.multiplier && next.addOn == t.addOn && next.cost == t.cost)
        assert(next.id != t.id, "续投是新的一张票，不能共用 id")

        // 5+0 → 三等奖, and a 完全不沾边 ticket pays nothing.
        t.back = [1, 3]
        assert(LotteryRules.settle(t, draw: draw).prize == 6666 * 3)
        t.front = [1, 3, 5, 7, 11]
        assert(LotteryRules.settle(t, draw: draw).prize == 0)
    }

    /// Payloads recorded from the live APIs, trimmed to the fields we decode.
    /// The second 双色球 item and the 大乐透 一等奖(追加) row carry the
    /// "no winner, so no published amount" shapes the fallbacks exist for.
    static func checkParsing() throws {
        let ssq = """
        {"state":0,"result":[
          {"code":"2026092","date":"2026-08-11(二)","red":"09,11,12,25,30,33","blue":"11",
           "poolmoney":"571623532","prizegrades":[
             {"type":1,"typemoney":"6466298"},{"type":2,"typemoney":"278411"},
             {"type":3,"typemoney":"3000"},{"type":4,"typemoney":"200"},
             {"type":5,"typemoney":"10"},{"type":6,"typemoney":"5"},{"type":7,"typemoney":""}]},
          {"code":"2026091","date":"2026-08-09(日)","red":"02,13,14,16,20,24","blue":"05",
           "poolmoney":"8000000","prizegrades":[{"type":1,"typemoney":""}]}]}
        """
        let draws = try LotteryRules.parseSSQ(Data(ssq.utf8))
        assert(draws.count == 2)
        assert(draws[0].num == 2026092 && draws[0].date == "2026-08-11")
        assert(draws[0].front == [9, 11, 12, 25, 30, 33] && draws[0].back == [11])
        assert(draws[0].prizes[1] == 6466298 && draws[0].prizes[6] == 5)
        assert(draws[0].prizes[7] == nil, "双色球 只有 6 个奖等，接口的 type 7 应被忽略")
        assert(draws[1].prizes[1] == 8_000_000, "一等奖 无人中奖时回落到奖池（未到封顶）")

        let dlt = """
        {"value":{"list":[
          {"lotteryDrawNum":"26090","lotteryDrawTime":"2026-08-10",
           "lotteryDrawResult":"09 14 17 19 24 02 09","poolBalanceAfterdraw":"825,721,619.33",
           "prizeLevelList":[
             {"prizeLevel":"一等奖","stakeAmountFormat":"10000000"},
             {"prizeLevel":"一等奖(追加)","stakeAmountFormat":"-1"},
             {"prizeLevel":"二等奖","stakeAmountFormat":"155846"},
             {"prizeLevel":"二等奖(追加)","stakeAmountFormat":"124677"},
             {"prizeLevel":"三等奖","stakeAmountFormat":"6666"},
             {"prizeLevel":"七等奖","stakeAmountFormat":"7"}]}]}}
        """
        let d = try LotteryRules.parseDLT(Data(dlt.utf8))[0]
        assert(d.num == 26090 && d.numText == "26090" && d.date == "2026-08-10")
        assert(d.front == [9, 14, 17, 19, 24] && d.back == [2, 9])
        assert(d.prizes[1] == 10_000_000 && d.prizes[7] == 7)
        assert(d.addOnPrizes[2] == 124677, "有中奖注数的追加奖金直接取接口值")
        assert(d.addOnPrizes[1] == 8_000_000, "无人中的追加奖金回落到基本奖金的 80%")
        assert(d.addOnPrizes[3] == nil, "接口没报追加行的奖级不发追加奖金")
    }

    static func main() throws {
        checkTable()
        checkTally()
        checkSettle()
        try checkParsing()
        print("lottery rules OK")
    }
}
#endif
