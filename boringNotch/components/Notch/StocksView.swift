//
//  StocksView.swift
//  boringNotch
//
//  Stocks tab (display-only — the notch panel never becomes key, so adding
//  symbols and configuring alerts live in Settings › Stocks): watchlist as a
//  two-column grid with intraday sparklines and change badges, filterable by
//  market (总/美/港/A) and sortable by change%. Double-click a card for
//  the detail page (intraday chart + open/high/low/prev-close/52w stats).
//  Data comes from StockManager / stock_bridge.py.
//

import Charts
import Defaults
import SwiftUI

struct StocksView: View {
    private enum SortMode {
        case watchlist, changeDesc, changeAsc

        var next: SortMode {
            switch self {
            case .watchlist: .changeDesc
            case .changeDesc: .changeAsc
            case .changeAsc: .watchlist
            }
        }

        var icon: String {
            switch self {
            case .watchlist: "arrow.up.arrow.down"
            case .changeDesc: "arrow.down.right"
            case .changeAsc: "arrow.up.right"
            }
        }

        var label: String {
            switch self {
            case .watchlist: "自选序"
            case .changeDesc: "涨幅↓"
            case .changeAsc: "涨幅↑"
            }
        }
    }

    @ObservedObject private var manager = StockManager.shared
    @State private var market: StockMarket = .all
    @State private var sortMode: SortMode = .watchlist
    @State private var detailSymbol: String?
    @State private var showHistory = false

    var body: some View {
        Group {
            if showHistory {
                StockAlertHistoryView { showHistory = false }
            } else if let symbol = detailSymbol {
                StockDetailView(symbol: symbol) { detailSymbol = nil }
            } else {
                listPage
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            if !manager.watchlist.isEmpty { manager.start() }
        }
    }

    private var displayQuotes: [StockQuote] {
        let quotes = manager.orderedQuotes(market: market)
        switch sortMode {
        case .watchlist:
            return quotes
        case .changeDesc:
            return quotes.sorted { ($0.changePct ?? -.infinity) > ($1.changePct ?? -.infinity) }
        case .changeAsc:
            return quotes.sorted { ($0.changePct ?? .infinity) < ($1.changePct ?? .infinity) }
        }
    }

    // MARK: List page

    private var listPage: some View {
        VStack(spacing: 0) {
            header
            if let banner = errorBanner {
                banner
            }
            if manager.watchlist.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible())],
                              spacing: 4) {
                        ForEach(displayQuotes) { quote in
                            StockCard(quote: quote) { detailSymbol = quote.symbol }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            ForEach(StockMarket.allCases) { m in
                Button {
                    withAnimation(.smooth) { market = m }
                } label: {
                    Text(m.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(market == m ? Color(nsColor: .secondarySystemFill) : .clear))
                        .foregroundStyle(market == m ? .white : .gray)
                }
                .buttonStyle(.plain)
            }
            Button {
                withAnimation(.smooth) { showHistory = true }
            } label: {
                Image(systemName: "bell")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
                    .overlay(alignment: .topTrailing) {
                        if manager.unreadAlertCount > 0 {
                            Circle().fill(.red).frame(width: 5, height: 5).offset(x: 2, y: -2)
                        }
                    }
            }
            .buttonStyle(.plain)
            .help("历史提醒")
            Spacer()
            Button {
                withAnimation(.smooth) { sortMode = sortMode.next }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: sortMode.icon)
                    Text(sortMode.label)
                }
                .font(.system(size: 10, weight: .medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .secondarySystemFill)))
                .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .help("切换排序：自选顺序 / 涨幅降序 / 涨幅升序")
            Button {
                SettingsWindowController.shared.showWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.gray)
            }
            .buttonStyle(.plain)
            .help("在设置中管理自选和提醒")
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
    }

    private var errorBanner: (some View)? {
        let message: String? = switch manager.state {
        case .failed(let error): error
        default: manager.bridgeError
        }
        guard let message else { return Optional<AnyView>.none }
        return AnyView(
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text(message)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("重试") {
                    Task {
                        await manager.stop()
                        manager.start()
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
            }
            .font(.caption2)
            .foregroundStyle(.gray)
            .padding(.horizontal, 12)
            .padding(.top, 4)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(.system(size: 30))
                .foregroundStyle(.gray)
            Text("暂无自选")
                .font(.headline)
                .foregroundStyle(.gray)
            Button("去设置中添加标的") {
                SettingsWindowController.shared.showWindow()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Card (half-width grid cell)

private struct StockCard: View {
    let quote: StockQuote
    var openDetail: () -> Void

    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(quote.displayName)
                    .font(.system(size: 11, weight: .semibold))
                    .lineLimit(1)
                Text(quote.symbol)
                    .font(.system(size: 8))
                    .foregroundStyle(.gray)
                    .lineLimit(1)
            }
            .frame(width: 74, alignment: .leading)
            StockSparkline(points: quote.rt ?? [],
                           lastClose: quote.ext?.base ?? quote.lastClose,
                           color: trendColor,
                           segments: quote.sessionSegments)
                .frame(maxWidth: .infinity)
                .frame(height: 26)
            VStack(alignment: .trailing, spacing: 2) {
                Text(StockManager.price(quote.ext?.price ?? quote.cur))
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                Text(StockManager.pct(displayPct))
                    .font(.system(size: 9, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(trendColor))
                if let ext = quote.ext {
                    Text(ext.label)
                        .font(.system(size: 8))
                        .foregroundStyle(.gray)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(hovering ? Color(nsColor: .secondarySystemFill).opacity(0.5) : .clear))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2, perform: openDetail)
        .contextMenu {
            Button("查看详情") { openDetail() }
            Button("删除", role: .destructive) {
                withAnimation(.smooth) { StockManager.shared.removeSymbol(quote.symbol) }
            }
        }
        .help("\(quote.symbol) · 双击查看详情")
    }

    /// Ext-session change% when live, else regular-session change%.
    private var displayPct: Double? {
        quote.ext?.changePct ?? quote.changePct
    }

    private var trendColor: Color {
        stockTrendColor(displayPct)
    }
}

/// Up/down color respecting the 红涨/绿涨 preference.
func stockTrendColor(_ changePct: Double?) -> Color {
    guard let changePct else { return .gray }
    return (changePct >= 0) == Defaults[.stockGreenUp] ? .green : .red
}

// MARK: - Sparkline

struct StockSparkline: View {
    let points: [StockQuote.RTPoint]
    let lastClose: Double?
    let color: Color
    var segments: [(start: Int, end: Int)] = [(570, 960)]

    /// Elapsed trading minutes at "HH:MM" (lunch break compressed away).
    private func elapsed(_ t: String) -> Int {
        let parts = t.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return 0 }
        let minuteOfDay = h * 60 + m
        var acc = 0
        for seg in segments {
            if minuteOfDay >= seg.end { acc += seg.end - seg.start }
            else { return acc + max(0, minuteOfDay - seg.start) }
        }
        return acc
    }

    private var sessionMinutes: Int {
        segments.reduce(0) { $0 + $1.end - $1.start }
    }

    var body: some View {
        if points.count < 2 {
            Rectangle().fill(.clear)
        } else {
            Chart {
                ForEach(Array(points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("t", elapsed(point.t)), y: .value("p", point.p))
                        .lineStyle(StrokeStyle(lineWidth: 1.2))
                    AreaMark(x: .value("t", elapsed(point.t)),
                             yStart: .value("min", yDomain.lowerBound),
                             yEnd: .value("p", point.p))
                        .foregroundStyle(LinearGradient(colors: [color.opacity(0.3), color.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                }
                if let lastClose {
                    RuleMark(y: .value("close", lastClose))
                        .lineStyle(StrokeStyle(lineWidth: 0.8, dash: [2, 2]))
                        .foregroundStyle(.gray.opacity(0.6))
                }
            }
            .foregroundStyle(color)
            .chartXScale(domain: 0...sessionMinutes)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: yDomain.lowerBound...yDomain.upperBound)
            .chartLegend(.hidden)
        }
    }

    private var yDomain: ClosedRange<Double> {
        var values = points.map(\.p)
        if let lastClose { values.append(lastClose) }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        let pad = max((high - low) * 0.08, high * 0.001)
        return (low - pad)...(high + pad)
    }
}

// MARK: - Alert history page

private struct StockAlertHistoryView: View {
    var back: () -> Void

    @ObservedObject private var manager = StockManager.shared

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                Text("历史提醒")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Button("清空") {
                    withAnimation(.smooth) { manager.clearAlertHistory() }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(manager.firedAlerts.isEmpty ? .gray : .red)
                .disabled(manager.firedAlerts.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            if manager.firedAlerts.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 24))
                        .foregroundStyle(.gray)
                    Text("暂无提醒记录")
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(manager.firedAlerts) { alert in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Text(Self.timeFormatter.string(from: alert.date))
                                    .font(.system(size: 9))
                                    .monospacedDigit()
                                    .foregroundStyle(.gray)
                                Text(alert.message)
                                    .font(.system(size: 11))
                                    .lineLimit(2)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .onAppear { manager.markAlertsRead() }
    }
}

// MARK: - Detail page

private struct StockDetailView: View {
    let symbol: String
    var back: () -> Void

    @ObservedObject private var manager = StockManager.shared

    private var quote: StockQuote { manager.quotes[symbol] ?? StockQuote(symbol: symbol) }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.gray)
                }
                .buttonStyle(.plain)
                VStack(alignment: .leading, spacing: 0) {
                    Text(quote.displayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(symbol)
                        .font(.system(size: 9))
                        .foregroundStyle(.gray)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 0) {
                    Text(StockManager.price(quote.ext?.price ?? quote.cur))
                        .font(.system(size: 15, weight: .bold))
                        .monospacedDigit()
                    HStack(spacing: 3) {
                        if let ext = quote.ext {
                            Text(ext.label)
                                .font(.system(size: 9))
                                .foregroundStyle(.gray)
                        }
                        Text(StockManager.pct(quote.ext?.changePct ?? quote.changePct))
                            .font(.system(size: 10, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(stockTrendColor(quote.ext?.changePct ?? quote.changePct))
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 8) {
                    StockSparkline(points: quote.rt ?? [],
                                   lastClose: quote.ext?.base ?? quote.lastClose,
                                   color: stockTrendColor(quote.ext?.changePct ?? quote.changePct),
                                   segments: quote.sessionSegments)
                        .frame(height: 84)
                        .padding(.horizontal, 12)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), alignment: .leading), count: 3),
                              spacing: 8) {
                        statCell("开盘价", StockManager.price(quote.open))
                        statCell("最高价", StockManager.price(quote.high))
                        statCell("最低价", StockManager.price(quote.low))
                        statCell("昨收价", StockManager.price(quote.lastClose))
                        statCell("52周最高", StockManager.price(quote.high52w))
                        statCell("52周最低", StockManager.price(quote.low52w))
                        statCell("成交量", StockManager.bigNumber(quote.volume))
                        statCell("成交额", StockManager.bigNumber(quote.turnover))
                        statCell("市盈率", quote.pe.map { String(format: "%.2f", $0) } ?? "–")
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
        }
        .task(id: symbol) {
            _ = await manager.fetchSnapshot(symbol)
        }
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.gray)
            Text(value)
                .font(.system(size: 11, weight: .semibold))
                .monospacedDigit()
        }
    }
}
