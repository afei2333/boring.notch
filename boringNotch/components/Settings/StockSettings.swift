//
//  StockSettings.swift
//  boringNotch
//
//  Settings › Stocks: watchlist management (add/remove symbols, per-symbol
//  alert on/off), the shared alert template, notch alert style, up/down
//  colors and OpenD connection.
//  Lives here because the notch panel never becomes key, so text input is
//  impossible there — the notch Stocks tab is display-only.
//

import Defaults
import SwiftUI

struct StockSettings: View {
    @ObservedObject private var manager = StockManager.shared
    @Default(.stockAlertExplicit) var alertExplicit
    @Default(.stockAlertChangePct) var alertChangePct
    @Default(.stockAlertReversalPct) var alertReversalPct
    @Default(.stockGreenUp) var greenUp
    @Default(.futuOpenDPort) var openDPort
    @Default(.stockPythonPath) var pythonPath
    @State private var newSymbol = ""
    @State private var suggestions: [StockSearchResult] = []
    @State private var searchLoading = false
    @State private var searchTask: Task<Void, Never>?
    @State private var addRejected = false

    var body: some View {
        Form {
            Section("自选标的") {
                HStack {
                    TextField("代码或名称，如 腾讯 / AAPL / HK.00700", text: $newSymbol)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSymbol)
                        .onChange(of: newSymbol) { _, query in
                            addRejected = false
                            searchTask?.cancel()
                            let trimmed = query.trimmingCharacters(in: .whitespaces)
                            guard !trimmed.isEmpty else {
                                suggestions = []
                                searchLoading = false
                                return
                            }
                            searchTask = Task {
                                try? await Task.sleep(for: .milliseconds(250))
                                guard !Task.isCancelled else { return }
                                let (results, loading) = await manager.search(trimmed)
                                guard !Task.isCancelled else { return }
                                suggestions = results
                                searchLoading = loading
                            }
                        }
                    Button("添加", action: addSymbol)
                        .disabled(newSymbol.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if addRejected {
                    Text("无法识别的代码 — 输入名称或代码后从搜索结果中选择")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if searchLoading, !newSymbol.isEmpty {
                    Text("正在从 OpenD 加载标的列表，结果可能不全…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ForEach(suggestions.prefix(8)) { result in
                    Button {
                        manager.addSymbol(result.symbol)
                        newSymbol = ""
                        suggestions = []
                    } label: {
                        HStack {
                            Text(result.name.isEmpty ? result.symbol : result.name)
                            Text(result.symbol)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Image(systemName: manager.watchlist.contains { $0.symbol == result.symbol }
                                  ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if manager.watchlist.isEmpty {
                    Text("尚未添加自选")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(manager.watchlist, id: \.symbol) { stock in
                        StockWatchlistRow(symbol: stock.symbol)
                    }
                }
            }

            Section("提醒模版（对所有开启提醒的标的生效）") {
                StockThresholdRow(label: "涨跌幅 ≥ (%)", value: $alertChangePct, defaultValue: 3)
                StockThresholdRow(label: "反转回撤 ≥ (%)", value: $alertReversalPct, defaultValue: 2)
                Picker("刘海提醒方式", selection: $alertExplicit) {
                    Text("显式 · 显示消息全文和数量").tag(true)
                    Text("隐式 · 只显示提醒数量").tag(false)
                }
                Text("触发后自动重新武装（回到阈值 80% 以内），可重复提醒")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("显示") {
                Toggle("绿涨红跌（关闭则红涨绿跌）", isOn: $greenUp)
            }

            Section("连接") {
                TextField("OpenD 端口", value: $openDPort, format: .number.grouping(.never))
                TextField("Python 解释器（需已安装 futu-api）", text: $pythonPath)
                HStack {
                    Text(stateDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("重启桥接") {
                        Task {
                            await manager.stop()
                            manager.start()
                        }
                    }
                }
            }
        }
        .navigationTitle("Stocks")
    }

    private var stateDescription: String {
        switch manager.state {
        case .stopped: "桥接未运行"
        case .starting: "桥接启动中…"
        case .ready(let port): "桥接运行中 · 127.0.0.1:\(port)" + (manager.bridgeError.map { " · \($0)" } ?? "")
        case .failed(let error): "桥接启动失败：\(error)"
        }
    }

    private func addSymbol() {
        // Prefer the top suggestion so 回车 on a name query adds the right code.
        let added = suggestions.first.map { manager.addSymbol($0.symbol) }
            ?? manager.addSymbol(newSymbol)
        if added {
            newSymbol = ""
            suggestions = []
        }
        addRejected = !added
    }
}

/// One watchlist entry: symbol/name/price line, alert on/off, delete.
private struct StockWatchlistRow: View {
    let symbol: String
    @ObservedObject private var manager = StockManager.shared

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(manager.quotes[symbol]?.displayName ?? symbol)
                    .fontWeight(.medium)
                Text(symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let quote = manager.quotes[symbol], quote.cur != nil {
                Text(StockManager.price(quote.cur))
                    .monospacedDigit()
                Text(StockManager.pct(quote.changePct))
                    .monospacedDigit()
                    .font(.caption)
                    .foregroundStyle(stockTrendColor(quote.changePct))
            }
            if let binding = manager.binding(for: symbol) {
                Toggle(isOn: binding.alertsEnabled) {
                    Image(systemName: binding.alertsEnabled.wrappedValue ? "bell.fill" : "bell.slash")
                        .foregroundStyle(binding.alertsEnabled.wrappedValue ? .yellow : .secondary)
                }
                .toggleStyle(.button)
                .buttonStyle(.plain)
                .help("该标的是否提醒")
            }
            Button {
                withAnimation { manager.removeSymbol(symbol) }
            } label: {
                Image(systemName: "trash")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("删除")
        }
    }
}

struct StockThresholdRow: View {
    let label: String
    @Binding var value: Double?
    let defaultValue: Double

    var body: some View {
        HStack {
            Toggle(isOn: Binding(
                get: { value != nil },
                set: { value = $0 ? defaultValue : nil }
            )) {
                Text(label)
            }
            .toggleStyle(.checkbox)
            Spacer()
            if value != nil {
                TextField("", value: Binding(get: { value ?? defaultValue },
                                             set: { value = $0 }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 90)
                    .multilineTextAlignment(.trailing)
            }
        }
    }
}
