//
//  LotteryView.swift
//  boringNotch
//
//  赛博彩票 tab. First screen is what you actually come back for — the ledger
//  and what is still 待开奖 — with 选号 and 历史记录 living behind overlays,
//  because a 33+16 ball grid needs the whole panel to itself.
//
//  Settled tickets move out of the main list into 历史记录, where a double click
//  expands the draw. The ledger on top still counts everything.
//
//  Data and rules: LotteryManager / LotteryRules.
//

import SwiftUI

struct LotteryView: View {
    @ObservedObject private var manager = LotteryManager.shared
    @State private var picking = false
    @State private var browsingHistory = false

    var body: some View {
        Group {
            if picking {
                LotteryPicker { picking = false }
            } else if browsingHistory {
                LotteryHistory { browsingHistory = false }
            } else {
                listPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task { await manager.refresh() }
    }

    // MARK: List page

    private var listPage: some View {
        VStack(spacing: 0) {
            header
            if let error = manager.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
            }
            if manager.pending.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(manager.pending) { TicketRow(ticket: $0) }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            ledgerItem("投入", LotteryFormat.money(Double(manager.totalCost)), .gray)
            ledgerItem("中奖", LotteryFormat.money(manager.totalPrize), .gray)
            ledgerItem("净盈亏", LotteryFormat.signed(manager.net), manager.net >= 0 ? .green : .red)
            Spacer()
            Button {
                Task { await manager.refresh(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(manager.refreshing ? .white : .gray)
                    .rotationEffect(.degrees(manager.refreshing ? 360 : 0))
                    .animation(manager.refreshing ? .linear(duration: 1).repeatForever(autoreverses: false)
                                                  : .default, value: manager.refreshing)
            }
            .buttonStyle(.plain)
            .disabled(manager.refreshing)
            .help("重新拉取开奖结果并结算待开奖的票")
            Button {
                withAnimation(.smooth) { browsingHistory = true }
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                    .foregroundStyle(.white)
                    .overlay(alignment: .topTrailing) {
                        if manager.unseenWins > 0 {
                            Text("\(manager.unseenWins)")
                                .font(.system(size: 8, weight: .bold))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .padding(.horizontal, 3)
                                .frame(minWidth: 12, minHeight: 12)
                                .background(Capsule().fill(.red))
                                .offset(x: 5, y: -5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help(manager.unseenWins > 0 ? "有 \(manager.unseenWins) 张中奖的票还没看" : "已开奖的票都在这里")
            Button {
                withAnimation(.smooth) { picking = true }
            } label: {
                Label("去投注", systemImage: "plus")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func ledgerItem(_ label: String, _ value: String, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(label)
                .font(.system(size: 8))
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint == .gray ? .white : tint)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "ticket")
                .font(.system(size: 28))
                .foregroundStyle(.gray)
            Text(manager.tickets.isEmpty ? "还没买过，一注两块钱的希望" : "没有待开奖的票，历史都在右上角")
                .font(.system(size: 12))
                .foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - History overlay

private struct LotteryHistory: View {
    var close: () -> Void

    @ObservedObject private var manager = LotteryManager.shared
    @State private var expanded: Set<UUID> = []

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: close) {
                    Image(systemName: "chevron.left").font(.system(size: 11)).foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                Text("历史记录")
                    .font(.system(size: 11, weight: .medium))
                Spacer()
                Text("\(manager.history.count) 张 · 双击看开奖")
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if manager.history.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.system(size: 28))
                        .foregroundStyle(.gray)
                    Text("还没有开过奖的票")
                        .font(.system(size: 12))
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 3) {
                        ForEach(manager.history) { ticket in
                            TicketRow(ticket: ticket, expanded: expanded.contains(ticket.id))
                                .onTapGesture(count: 2) {
                                    withAnimation(.smooth) {
                                        if !expanded.insert(ticket.id).inserted {
                                            expanded.remove(ticket.id)
                                        }
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                }
            }
        }
        .onAppear { manager.markHistorySeen() }
    }
}

// MARK: - Ticket row

private struct TicketRow: View {
    let ticket: LotteryTicket
    /// 历史记录 only: double click expands the draw below the row.
    var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            summary
            if expanded, let result = ticket.result { drawDetail(result) }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .secondarySystemFill).opacity(0.4)))
        .contentShape(Rectangle())
        .help(detail)
    }

    private var summary: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(ticket.game.title)
                    .font(.system(size: 10, weight: .semibold))
                Text(ticket.result.map { "\($0.drawText) 期" } ?? "下期")
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
            }
            .frame(width: 52, alignment: .leading)

            BallRow(front: ticket.front, back: ticket.back, size: 15)

            if ticket.multiplier > 1 || ticket.addOn || ticket.stakes > 1 {
                Text([ticket.stakes > 1 ? "\(ticket.stakes)注" : nil,
                      ticket.multiplier > 1 ? "×\(ticket.multiplier)" : nil,
                      ticket.addOn ? "追" : nil].compactMap { $0 }.joined(separator: " "))
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.gray)
                    .fixedSize()
            }

            Spacer(minLength: 4)

            autoBadge

            Text("−¥\(ticket.cost)")
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.gray)

            statusBadge
                .frame(width: 86, alignment: .trailing)
        }
    }

    /// 自动续投 marker. On a 待开奖 ticket it is also the off switch — the chain
    /// re-buys itself every 期, so stopping it has to be one click away.
    @ViewBuilder
    private var autoBadge: some View {
        if ticket.isPending {
            Button { LotteryManager.shared.toggleAuto(ticket) } label: { autoLabel }
                .buttonStyle(.plain)
                .help(ticket.auto ? "开奖后自动投同样的号码到下一期，点一下关闭" : "点一下开启自动续投，开奖后自动买下一期")
        } else if ticket.auto {
            autoLabel.help("自动续投买下的票")
        }
    }

    private var autoLabel: some View {
        Label("自动", systemImage: "repeat")
            .labelStyle(.titleAndIcon)
            .font(.system(size: 8, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(ticket.auto ? Color.blue.opacity(0.85)
                                                   : Color(nsColor: .secondarySystemFill).opacity(0.6)))
            .foregroundStyle(ticket.auto ? .white : .gray)
    }

    /// Expanded body: the draw itself, then the ticket's own numbers with the
    /// misses faded out so the hits read at a glance.
    private func drawDetail(_ result: LotteryResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().opacity(0.35)
            HStack(spacing: 6) {
                caption("开奖")
                BallRow(front: result.front, back: result.back, size: 16)
                Text(result.date)
                    .font(.system(size: 9))
                    .foregroundStyle(.gray)
            }
            HStack(spacing: 6) {
                caption("我的")
                BallRow(front: ticket.front, back: ticket.back, size: 16,
                        hit: (Set(result.front), Set(result.back)), limit: .max)
            }
            HStack(spacing: 6) {
                caption("结果")
                Text(levels(result).isEmpty ? "未中奖" : levels(result))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(result.prize > 0 ? .yellow : .gray)
                if result.prize > 0 {
                    Text("共 " + LotteryFormat.money(result.prize))
                        .font(.system(size: 9, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(.yellow)
                }
            }
        }
        .padding(.bottom, 2)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9))
            .foregroundStyle(.gray)
            .frame(width: 24, alignment: .leading)
    }

    private func levels(_ result: LotteryResult) -> String {
        result.hits.sorted { $0.key < $1.key }
            .map { "\(LotteryFormat.levelName($0.key)) × \($0.value * ticket.multiplier) 注" }
            .joined(separator: "，")
    }

    @ViewBuilder
    private var statusBadge: some View {
        if let result = ticket.result {
            if result.prize > 0 {
                Text("中 " + LotteryFormat.money(result.prize))
                    .font(.system(size: 11, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
            } else {
                Text("未中奖")
                    .font(.system(size: 10))
                    .foregroundStyle(.gray)
            }
        } else {
            Text("待开奖")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.blue)
        }
    }

    /// Tooltip: winning numbers and which 奖级 landed — no room for it inline.
    private var detail: String {
        guard let result = ticket.result else {
            return "买于 \(ticket.purchasedAt.formatted(date: .abbreviated, time: .shortened))，等待下一期开奖"
        }
        let numbers = (result.front.map(LotteryFormat.ball) + ["|"] + result.back.map(LotteryFormat.ball))
            .joined(separator: " ")
        let won = levels(result)
        return "\(result.drawText) 期（\(result.date)）开出 \(numbers)"
            + (won.isEmpty ? "\n未中奖" : "\n中 \(won)")
    }
}

// MARK: - Picker overlay

private struct LotteryPicker: View {
    var close: () -> Void

    @ObservedObject private var manager = LotteryManager.shared
    @State private var game: LotteryGame = .ssq
    @State private var front: Set<Int> = []
    @State private var back: Set<Int> = []
    @State private var multiplier = 1
    @State private var addOn = false
    @State private var auto = false

    private var stakes: Int {
        guard game.frontRange.contains(front.count), game.backRange.contains(back.count) else { return 0 }
        return LotteryRules.comb(front.count, game.frontPick) * LotteryRules.comb(back.count, game.backPick)
    }

    private var cost: Int {
        stakes * multiplier * (LotteryGame.unitPrice + (addOn && game.supportsAddOn ? LotteryGame.addOnPrice : 0))
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 4) {
                    grid(name: game.frontName, range: game.frontRange, max: game.frontMax,
                         selection: $front, tint: .red)
                    grid(name: game.backName, range: game.backRange, max: game.backMax,
                         selection: $back, tint: .blue)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
            }
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Button(action: close) {
                Image(systemName: "chevron.left").font(.system(size: 11)).foregroundStyle(.gray)
            }
            .buttonStyle(.plain)

            ForEach(LotteryGame.allCases) { g in
                Button {
                    guard g != game else { return }
                    withAnimation(.smooth) {
                        game = g
                        front = []; back = []; multiplier = 1; addOn = false
                    }
                } label: {
                    Text(g.title)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(game == g ? Color(nsColor: .secondarySystemFill) : .clear))
                        .foregroundStyle(game == g ? .white : .gray)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            Button("机选") {
                let pick = LotteryRules.quickPick(game)
                withAnimation(.smooth) { front = Set(pick.front); back = Set(pick.back) }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.blue)

            Button("清空") {
                withAnimation(.smooth) { front = []; back = [] }
            }
            .buttonStyle(.plain)
            .font(.system(size: 10))
            .foregroundStyle(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private func grid(name: String, range: ClosedRange<Int>, max: Int,
                      selection: Binding<Set<Int>>, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("\(name) 选 \(range.lowerBound)–\(range.upperBound) 个（已选 \(selection.wrappedValue.count)）")
                .font(.system(size: 8))
                .foregroundStyle(.gray)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 21), spacing: 3)], spacing: 3) {
                ForEach(1...max, id: \.self) { n in
                    let on = selection.wrappedValue.contains(n)
                    Button {
                        if on {
                            selection.wrappedValue.remove(n)
                        } else if selection.wrappedValue.count < range.upperBound {
                            selection.wrappedValue.insert(n)
                        }
                    } label: {
                        Text(LotteryFormat.ball(n))
                            .font(.system(size: 9, weight: .semibold))
                            .monospacedDigit()
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(on ? tint : Color(nsColor: .secondarySystemFill).opacity(0.5)))
                            .foregroundStyle(on ? .white : .gray)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 8) {
            Text("倍数")
                .font(.system(size: 9))
                .foregroundStyle(.gray)
            Stepper(value: $multiplier, in: 1...LotteryGame.maxMultiplier) {
                Text("\(multiplier)")
                    .font(.system(size: 10, weight: .medium))
                    .monospacedDigit()
                    .frame(width: 18)
            }
            .controlSize(.mini)

            if game.supportsAddOn {
                Toggle("追加", isOn: $addOn)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 10))
                    .help("每注多 1 元，一、二等奖多拿 80% 的追加奖金")
            }

            Toggle("自动续投", isOn: $auto)
                .toggleStyle(.checkbox)
                .font(.system(size: 10))
                .help("每期开奖后自动用同样的号码投下一期，省得漏参与；在列表里点“自动”标识可随时停")

            Spacer()

            Text(stakes > 0 ? "\(stakes) 注 · ¥\(cost)" : "选够号才能投注")
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(stakes > 0 ? .white : .gray)

            Button {
                guard manager.buy(game: game, front: front.sorted(), back: back.sorted(),
                                  multiplier: multiplier, addOn: addOn, auto: auto) else { return }
                withAnimation(.smooth) { close() }
            } label: {
                Text("投注")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(canBuy ? Color.accentColor : Color(nsColor: .secondarySystemFill)))
                    .foregroundStyle(canBuy ? .white : .gray)
            }
            .buttonStyle(.plain)
            .disabled(!canBuy)
            .help(manager.latest[game] == nil
                  ? "还没拉到\(game.title)的最新开奖，无法确定投注哪一期"
                  : "投注下一期（最新已开 \(manager.latest[game]!.numText) 期）")
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private var canBuy: Bool { stakes > 0 && manager.latest[game] != nil }
}

// MARK: - Shared bits

private struct BallRow: View {
    let front: [Int]
    let back: [Int]
    let size: CGFloat
    /// Winning numbers to mark. nil = every ball drawn at full strength;
    /// otherwise the misses fade and the hits get a ring.
    var hit: (front: Set<Int>, back: Set<Int>)?
    /// 复式 tickets can carry 20 red balls; the panel is 640pt wide, so past a
    /// dozen the row collapses to a count. `.max` shows them all.
    var limit = 12

    private var shownFront: [Int] { Array(front.prefix(limit)) }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(shownFront, id: \.self) { ball($0, .red, hit?.front.contains($0)) }
            if front.count > shownFront.count {
                Text("+\(front.count - shownFront.count)")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.gray)
            }
            ForEach(back, id: \.self) { ball($0, .blue, hit?.back.contains($0)) }
        }
        .fixedSize()
    }

    /// `won` nil means "not marking hits at all".
    private func ball(_ n: Int, _ tint: Color, _ won: Bool?) -> some View {
        Text(LotteryFormat.ball(n))
            .font(.system(size: size * 0.6, weight: .semibold))
            .monospacedDigit()
            .frame(width: size, height: size)
            .background(Circle().fill(tint.opacity(won == false ? 0.2 : 0.85)))
            .overlay { if won == true { Circle().strokeBorder(.white, lineWidth: 1) } }
            .foregroundStyle(won == false ? .gray : .white)
    }
}

enum LotteryFormat {
    static func ball(_ n: Int) -> String { String(format: "%02d", n) }

    static func money(_ value: Double) -> String {
        "¥" + (Self.grouping.string(from: NSNumber(value: value.rounded())) ?? "0")
    }

    static func signed(_ value: Double) -> String {
        (value >= 0 ? "+" : "−") + money(abs(value))
    }

    static func levelName(_ level: Int) -> String {
        let cn = ["一", "二", "三", "四", "五", "六", "七", "八", "九"]
        return (level <= cn.count ? cn[level - 1] : "\(level)") + "等奖"
    }

    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f
    }()
}
