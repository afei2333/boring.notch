//
//  BoringCalendar.swift
//  boringNotch
//
//  Created by Harsh Vardhan  Goswami  on 08/09/24.
//

import AppKit
import Defaults
import SwiftUI

struct Config: Equatable {
    //    var count: Int = 10  // 3 days past + today + 7 days future
    var past: Int = 200
    var future: Int = 200
    var steps: Int = 1  // Each step is one day
    var spacing: CGFloat = 0
    var showsText: Bool = true
    var offset: Int = 2  // Number of dates to the left of the selected date
}

struct WheelPicker: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var holidays = ChineseHolidays.shared
    @ObservedObject private var calendarManager = CalendarManager.shared
    @Binding var selectedDate: Date
    @State private var scrollPosition: Int?
    @State private var haptics: Bool = false
    @State private var byClick: Bool = false
    let config: Config

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: config.spacing) {  // 400+ cells — keep off-screen ones unbuilt
                let spacerNum = config.offset
                let dateCount = totalDateItems()
                let totalItems = dateCount + 2 * spacerNum
                ForEach(0..<totalItems, id: \.self) { index in
                    if index < spacerNum || index >= spacerNum + dateCount {
                        // Leading/trailing spacers sized to match a date cell
                        Spacer()
                            .frame(width: 24, height: 24)
                            .id(index)
                    } else {
                        let date = dateForItemIndex(index: index, spacerNum: spacerNum)
                        let isSelected = Calendar.current.isDate(date, inSameDayAs: selectedDate)
                        dateButton(date: date, isSelected: isSelected, id: index) {
                            selectedDate = date
                            byClick = true
                            withAnimation {
                                scrollPosition = index
                            }
                            if Defaults[.enableHaptics] {
                                haptics.toggle()
                            }
                        }
                    }
                }
            }
            .frame(height: 50)
            .scrollTargetLayout()
        }
        .scrollIndicators(.never)
        .scrollPosition(id: $scrollPosition, anchor: .center)
        .scrollTargetBehavior(.viewAligned)  // Ensures scroll view snaps the centered view
        .safeAreaPadding(.horizontal)
        .sensoryFeedback(.alignment, trigger: haptics)
        .onChange(of: scrollPosition) { oldValue, newValue in
            if byClick {
                byClick = false
            } else {
                handleScrollChange(newValue: newValue, config: config)
            }
        }
        .onAppear {
            scrollToToday(config: config)
            holidays.ensureLoaded(around: Date(), past: config.past, future: config.future)
        }
        // Mouse wheel steps the date; trackpad keeps native horizontal scrolling.
        .background(WheelStepper { step in
            let cal = Calendar.current
            let today = cal.startOfDay(for: Date())
            guard let lo = cal.date(byAdding: .day, value: -config.past, to: today),
                  let hi = cal.date(byAdding: .day, value: config.future, to: today),
                  let raw = cal.date(byAdding: .day, value: step, to: selectedDate)
            else { return }
            let next = min(max(cal.startOfDay(for: raw), lo), hi)  // clamp flings to the range
            guard next != cal.startOfDay(for: selectedDate) else { return }
            byClick = true  // we drive the scroll ourselves; skip the onChange re-center
            selectedDate = next
            // Instant snap, no animation: each tick lands on the next detent
            // like a slot-machine reel — animated glides stuttered here.
            scrollPosition = indexForDate(next)
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        })
        // When parent updates the bound selectedDate (e.g., view reopen), center the wheel on it
        .onChange(of: selectedDate) { _, newValue in
            let targetIndex = indexForDate(newValue)
            if scrollPosition != targetIndex {
                byClick = true
                withAnimation {
                    scrollPosition = targetIndex
                }
            }
        }
    }

    private func dateButton(
        date: Date, isSelected: Bool, id: Int, onClick: @escaping () -> Void
    ) -> some View {
        let isToday = Calendar.current.isDateInToday(date)
        return Button(action: onClick) {
            VStack(spacing: 8) {
                dayText(date: date, isToday: isToday, isSelected: isSelected)
                dateCircle(date: date, isToday: isToday, isSelected: isSelected)
            }
            .padding(.vertical, 4)
            .padding(.horizontal, 4)
            .background(isSelected ? Color.effectiveAccentBackground : Color.clear)
            .cornerRadius(8)
        }
        .buttonStyle(PlainButtonStyle())
        .id(id)
    }

    private func dayText(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        Text(dateToString(for: date))
            .font(.caption)
            .foregroundColor(isSelected ? .primary : .secondary)
    }

    /// Date-number tint: 法定休 red, 调休班 orange, 有日程 blue, 节日/节气 teal.
    private func statusColor(for date: Date) -> Color? {
        if let legal = holidays.status(for: date) {
            return legal.isOffDay ? .red : .orange
        }
        if calendarManager.eventDays.contains(Calendar.current.startOfDay(for: date)) {
            return .blue
        }
        return Festival.names(for: date).isEmpty ? nil : .teal
    }

    private func dateCircle(date: Date, isToday: Bool, isSelected: Bool) -> some View {
        ZStack {
            Circle()
                .fill(isToday ? Color.effectiveAccent : .clear)
                .frame(width: 20, height: 20)
                .overlay(
                    Circle()
                        .stroke(Color.gray.opacity(0.3), lineWidth: 0)
                )
            Text("\(date.date)")
                .font(.body)
                .fontWeight(.medium)
                // White only on the solid accent circle (today); elsewhere the
                // background is translucent, so use adaptive colors.
                .foregroundColor(
                    isToday ? .white
                        : statusColor(for: date) ?? (isSelected ? .primary : .secondary))
        }
    }

    func handleScrollChange(newValue: Int?, config: Config) {
        guard let newIndex = newValue else { return }
        let spacerNum = config.offset
        let dateCount = totalDateItems()
        guard (spacerNum..<(spacerNum + dateCount)).contains(newIndex) else { return }
        let date = dateForItemIndex(index: newIndex, spacerNum: spacerNum)
        if !Calendar.current.isDate(date, inSameDayAs: selectedDate) {
            selectedDate = date
            if Defaults[.enableHaptics] {
                haptics.toggle()
            }
        }
    }

    private func scrollToToday(config: Config) {
        let today = Date()
        byClick = true
        scrollPosition = indexForDate(today)
        selectedDate = today
    }

    // MARK: - Index/Date mapping with steps and spacers
    private func indexForDate(_ date: Date) -> Int {
        let spacerNum = config.offset
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.startOfDay(for: cal.date(byAdding: .day, value: -config.past, to: today) ?? today)
        let target = cal.startOfDay(for: date)
        let days = cal.dateComponents([.day], from: startDate, to: target).day ?? 0
        let stepIndex = max(0, min(days / max(config.steps, 1), totalDateItems() - 1))
        return spacerNum + stepIndex
    }

    private func dateForItemIndex(index: Int, spacerNum: Int) -> Date {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let startDate = cal.date(byAdding: .day, value: -config.past, to: today) ?? today
        let stepIndex = index - spacerNum
        return cal.date(byAdding: .day, value: stepIndex * max(config.steps, 1), to: startDate) ?? today
    }

    private func totalDateItems() -> Int {
        let range = config.past + config.future
        let step = max(config.steps, 1)
        return Int(ceil(Double(range) / Double(step))) + 1
    }

    private func dateToString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "E"
        return formatter.string(from: date)
    }
}

/// 法定节假日/调休安排, one JSON per year from the NateScarlet/holiday-cn
/// dataset (国务院文件的机器可读版), disk-cached for 30 days.
@MainActor
final class ChineseHolidays: ObservableObject {
    static let shared = ChineseHolidays()
    struct Day: Decodable {
        let name: String
        let date: String  // "yyyy-MM-dd"
        let isOffDay: Bool
    }
    @Published private(set) var days: [String: Day] = [:]  // keyed by date string
    private var requested: Set<Int> = []

    private static let keyFormat: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    func status(for date: Date) -> Day? {
        days[Self.keyFormat.string(from: date)]
    }

    /// Load every year the strip can reach; no-op after the first call.
    func ensureLoaded(around center: Date, past: Int, future: Int) {
        let cal = Calendar.current
        let bounds = [cal.date(byAdding: .day, value: -past, to: center), center,
                      cal.date(byAdding: .day, value: future, to: center)]
        let years = Set(bounds.compactMap { $0.map { cal.component(.year, from: $0) } })
        for year in years where !requested.contains(year) {
            requested.insert(year)
            Task { await self.load(year: year) }
        }
    }

    private func load(year: Int) async {
        struct File: Decodable { let days: [Day] }
        let cacheURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("holiday-cn-\(year).json")
        var data = try? Data(contentsOf: cacheURL)
        let age = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate] as? Date)
            .map { -$0.timeIntervalSinceNow } ?? .infinity
        if data == nil || age > 30 * 86400 {
            // jsdelivr first (reachable in CN), github raw as fallback
            for host in ["https://cdn.jsdelivr.net/gh/NateScarlet/holiday-cn@master",
                         "https://raw.githubusercontent.com/NateScarlet/holiday-cn/master"] {
                if let url = URL(string: "\(host)/\(year).json"),
                   let (fresh, resp) = try? await URLSession.shared.data(from: url),
                   (resp as? HTTPURLResponse)?.statusCode == 200 {
                    data = fresh
                    try? fresh.write(to: cacheURL)
                    break
                }
            }
        }
        guard let data, let file = try? JSONDecoder().decode(File.self, from: data) else { return }
        for day in file.days {
            days[day.date] = day
        }
    }
}

/// Consumes discrete mouse-wheel ticks over this view and reports ±1 steps.
/// Trackpad events (precise deltas) pass through to the underlying ScrollView.
private struct WheelStepper: NSViewRepresentable {
    let onStep: (Int) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.installMonitor(on: view)
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}
    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }
    func makeCoordinator() -> Coordinator { Coordinator(onStep: onStep) }

    @MainActor final class Coordinator: NSObject {
        private let onStep: (Int) -> Void
        private var monitor: Any?
        private var position: Double = 0  // fractional days pending (1-line-delta mice)

        init(onStep: @escaping (Int) -> Void) {
            self.onStep = onStep
        }

        func installMonitor(on view: NSView) {
            removeMonitor()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) { [weak self, weak view] event in
                guard let self, let view,
                      event.window === view.window,
                      !event.hasPreciseScrollingDeltas,  // mouse wheel only
                      view.bounds.contains(view.convert(event.locationInWindow, from: nil))
                else { return event }
                self.handleTick(event.scrollingDeltaY)
                return nil  // consumed; don't let the ScrollView rubber-band
            }
        }

        private func handleTick(_ deltaY: CGFloat) {
            guard deltaY != 0 else { return }
            let impulse = -Double(deltaY) / 3.0  // one notch (±3 lines) ≈ 1 day; down -> forward
            if position != 0, impulse.sign != position.sign { position = 0 }  // reversing resets
            position += impulse
            let whole = Int(position)  // truncates toward zero
            if whole != 0 {
                position -= Double(whole)
                onStep(whole)  // detent snap, stops the moment the wheel stops
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            position = 0
        }
    }
}

struct CalendarView: View {
    @EnvironmentObject var vm: BoringViewModel
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var holidays = ChineseHolidays.shared
    @State private var selectedDate = Date()
    @State private var headerWidth: CGFloat = 0  // month/year column, to center content under the strip

    /// 休/班 badge + festival names for the selected date, shown atop the events.
    @ViewBuilder
    private var festivalRow: some View {
        let legal = holidays.status(for: selectedDate)
        let names = ([legal?.name] + Festival.names(for: selectedDate).map { $0 })
            .compactMap { $0 }
        if legal != nil || !names.isEmpty {
            HStack(spacing: 6) {
                if let legal {
                    Text(legal.isOffDay ? "休" : "班")
                        .font(.caption.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(legal.isOffDay ? Color.red : Color.orange)
                        .clipShape(Capsule())
                }
                Text(NSOrderedSet(array: names).array.compactMap { $0 as? String }
                    .joined(separator: " · "))
                    .font(.callout)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.top, 2)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading) {
                    Text(selectedDate.formatted(.dateTime.month(.abbreviated)))
                        .font(.title3)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(selectedDate.formatted(.dateTime.year()))
                        .font(.title3)
                        .fontWeight(.light)
                        .foregroundColor(.secondary)
                    Text(Festival.lunarString(for: selectedDate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .background(GeometryReader { g in
                    Color.clear.preference(key: HeaderWidthKey.self, value: g.size.width)
                })
                .onPreferenceChange(HeaderWidthKey.self) { headerWidth = $0 }

                WheelPicker(selectedDate: $selectedDate, config: Config())
                    // Fade the edges via a mask instead of overlaying black
                    // gradients, so it works on any background (light mode /
                    // liquid glass), not just the black notch.
                    .mask(
                        HStack(spacing: 0) {
                            LinearGradient(
                                colors: [.clear, .black], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 20)
                            Rectangle()
                            LinearGradient(
                                colors: [.black, .clear], startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: 20)
                        }
                    )
            }

            festivalRow

            let filteredEvents = EventListView.filteredEvents(
                events: calendarManager.events
            )
            if filteredEvents.isEmpty {
                EmptyEventsView(selectedDate: selectedDate)
                    .frame(maxWidth: .infinity)
                    .padding(.leading, headerWidth + 8)  // center under the strip, not the whole row
                Spacer(minLength: 0)
            } else {
                EventListView(events: calendarManager.events)
            }
        }
        .listRowBackground(Color.clear)
        .frame(height: 120)
        .onChange(of: selectedDate) {
            Task {
                await calendarManager.updateCurrentDate(selectedDate)
            }
        }
        .onChange(of: vm.notchState) { _, _ in
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
        .onAppear {
            Task {
                await calendarManager.updateCurrentDate(Date.now)
                selectedDate = Date.now
            }
        }
    }
}

private struct HeaderWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

struct EmptyEventsView: View {
    let selectedDate: Date
    
    var body: some View {
        VStack {
            Image(systemName: "calendar.badge.checkmark")
                .font(.title)
                .foregroundColor(.secondary)
            Text(Calendar.current.isDateInToday(selectedDate) ? "No events today" : "No events")
                .font(.subheadline)
                .foregroundColor(.primary)
            Text("Enjoy your free time!")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

struct EventListView: View {
    @Environment(\.openURL) private var openURL
    @ObservedObject private var calendarManager = CalendarManager.shared
    let events: [EventModel]
    @Default(.autoScrollToNextEvent) private var autoScrollToNextEvent
    @Default(.showFullEventTitles) private var showFullEventTitles


    static func filteredEvents(events: [EventModel]) -> [EventModel] {
        events.filter { event in
            if event.type.isReminder {
                if case .reminder(let completed) = event.type {
                    return !completed || !Defaults[.hideCompletedReminders]
                }
            }
            // Filter out all-day events if setting is enabled
            if event.isAllDay && Defaults[.hideAllDayEvents] {
                return false
            }
            return true
        }
    }

    private var filteredEvents: [EventModel] {
        Self.filteredEvents(events: events)
    }

    private func scrollToRelevantEvent(proxy: ScrollViewProxy) {
        let now = Date()
        // Determine a single target using preferred search order:
        // 1) first non-all-day upcoming/in-progress event
        // 2) first all-day event
        // 3) last event (fallback)
        let nonAllDayUpcoming = filteredEvents.first(where: { !$0.isAllDay && $0.end > now })
        let firstAllDay = filteredEvents.first(where: { $0.isAllDay })
        let lastEvent = filteredEvents.last
        guard let target = nonAllDayUpcoming ?? firstAllDay ?? lastEvent else { return }

        Task { @MainActor in
            withTransaction(Transaction(animation: nil)) {
                proxy.scrollTo(target.id, anchor: .top)
            }
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(filteredEvents) { event in
                    Button(action: {
                        if let url = event.calendarAppURL() {
                            openURL(url)
                        }
                    }) {
                        eventRow(event)
                    }
                    .id(event.id)
                    .padding(.leading, -5)
                    .buttonStyle(PlainButtonStyle())
                    .listRowSeparator(.automatic)
                    .listRowSeparatorTint(.gray.opacity(0.2))
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.never)
            .scrollContentBackground(.hidden)
            .background(Color.clear)
            .onAppear {
                scrollToRelevantEvent(proxy: proxy)
            }
            .onChange(of: filteredEvents) { _, _ in
                scrollToRelevantEvent(proxy: proxy)
            }
        }
        Spacer(minLength: 0)
    }

    private func eventRow(_ event: EventModel) -> some View {
        if event.type.isReminder {
            let isCompleted: Bool
            if case .reminder(let completed) = event.type {
                isCompleted = completed
            } else {
                isCompleted = false
            }
            return AnyView(
                HStack(spacing: 8) {
                    ReminderToggle(
                        isOn: Binding(
                            get: { isCompleted },
                            set: { newValue in
                                Task {
                                    await calendarManager.setReminderCompleted(
                                        reminderID: event.id, completed: newValue
                                    )
                                }
                            }
                        ),
                        color: Color(event.calendar.color)
                    )
                    .opacity(1.0)  // Ensure the toggle is always fully opaque
                    HStack {
                        Text(event.title)
                            .font(.callout)
                            .foregroundColor(.primary)
                            .lineLimit(showFullEventTitles ? nil : 1)
                        Spacer(minLength: 0)
                        VStack(alignment: .trailing, spacing: 4) {
                            if event.isAllDay {
                                Text("All-day")
                                    .font(.caption)
                                    .fontWeight(.medium)
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            } else {
                                Text(event.start, style: .time)
                                    .foregroundColor(.primary)
                                    .font(.caption)
                            }
                        }
                    }
                    .opacity(
                        isCompleted
                            ? 0.4
                            : event.start < Date.now && Calendar.current.isDateInToday(event.start)
                                ? 0.6 : 1.0
                    )
                }
                .padding(.vertical, 4)
            )
        } else {
            return AnyView(
                HStack(alignment: .top, spacing: 4) {
                    Rectangle()
                        .fill(Color(event.calendar.color))
                        .frame(width: 3)
                        .cornerRadius(1.5)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.callout)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                            .lineLimit(showFullEventTitles ? nil : 2)

                        if let location = event.location, !location.isEmpty {
                            Text(location)
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        if event.isAllDay {
                            Text("All-day")
                                .font(.caption)
                                .fontWeight(.medium)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        } else {
                            Text(event.start, style: .time)
                                .foregroundColor(.primary)
                            Text(event.end, style: .time)
                                .foregroundColor(.secondary)
                        }
                    }
                    .font(.caption)
                    .frame(minWidth: 44, alignment: .trailing)
                }
                .opacity(
                    event.eventStatus == .ended && Calendar.current.isDateInToday(event.start)
                        ? 0.6 : 1.0)
            )
        }
    }
}

struct ReminderToggle: View {
    @Binding var isOn: Bool
    var color: Color

    var body: some View {
        Button(action: {
            isOn.toggle()
        }) {
            ZStack {
                // Outer ring
                Circle()
                    .strokeBorder(color, lineWidth: 2)
                    .frame(width: 14, height: 14)
                // Inner fill
                if isOn {
                    Circle()
                        .fill(color)
                        .frame(width: 8, height: 8)
                }
                Circle()
                    .fill(Color.black.opacity(0.001))
                    .frame(width: 14, height: 14)
            }
        }
        .buttonStyle(PlainButtonStyle())
        .padding(0)
        .accessibilityLabel(isOn ? "Mark as incomplete" : "Mark as complete")
    }
}

#Preview {
    CalendarView()
        .frame(width: 215, height: 130)
        .background(.black)
        .environmentObject(BoringViewModel())
}
import Foundation

enum Festival {
    /// Every festival / solar-term name for a date (e.g. 2026-04-05 is both
    /// 清明 and 复活节), ordered 农历 > 公历 > 节气.
    static func names(for date: Date) -> [String] {
        [lunarFestival(date), gregorianFestival(date), solarTerm(date)].compactMap { $0 }
    }

    // MARK: 农历

    private static let chinese = Calendar(identifier: .chinese)
    private static let lunarMonthNames = [
        "正月", "二月", "三月", "四月", "五月", "六月",
        "七月", "八月", "九月", "十月", "冬月", "腊月",
    ]
    private static let lunarDayNames: [String] = {
        let digits = ["一", "二", "三", "四", "五", "六", "七", "八", "九", "十"]
        return (1...30).map { n in
            switch n {
            case 10: return "初十"
            case 20: return "二十"
            case 30: return "三十"
            default: return ["初", "十", "廿"][n / 10] + digits[n % 10 - 1]
            }
        }
    }()

    /// "闰六月初九"-style lunar date, or "" if out of range.
    static func lunarString(for date: Date) -> String {
        let c = chinese.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day,
              (1...12).contains(m), (1...30).contains(d) else { return "" }
        return ((c.isLeapMonth ?? false) ? "闰" : "") + lunarMonthNames[m - 1] + lunarDayNames[d - 1]
    }
    private static let lunarFestivals: [Int: String] = [
        101: "春节", 115: "元宵", 202: "龙抬头", 505: "端午", 707: "七夕",
        715: "中元", 815: "中秋", 909: "重阳", 1208: "腊八", 1223: "小年",
    ]

    private static func lunarFestival(_ date: Date) -> String? {
        let c = chinese.dateComponents([.month, .day], from: date)
        guard let m = c.month, let d = c.day, !(c.isLeapMonth ?? false) else { return nil }
        if let name = lunarFestivals[m * 100 + d] { return name }
        // 除夕: the day before 正月初一
        if m == 12, d >= 29,
           let next = Calendar.current.date(byAdding: .day, value: 1, to: date) {
            let n = chinese.dateComponents([.month, .day], from: next)
            if n.month == 1 && n.day == 1 && !(n.isLeapMonth ?? false) { return "除夕" }
        }
        return nil
    }

    // MARK: 公历

    private static let gregorianFestivals: [Int: String] = [
        101: "元旦", 214: "情人节", 308: "妇女节", 312: "植树节", 401: "愚人节",
        501: "劳动节", 504: "青年节", 601: "儿童节", 910: "教师节", 1001: "国庆节",
        1031: "万圣节", 1224: "平安夜", 1225: "圣诞节",
    ]

    private static func gregorianFestival(_ date: Date) -> String? {
        let c = Calendar.current.dateComponents([.year, .month, .day, .weekday, .weekdayOrdinal], from: date)
        guard let y = c.year, let m = c.month, let d = c.day else { return nil }
        if let name = gregorianFestivals[m * 100 + d] { return name }
        if easter(year: y) == (m, d) { return "复活节" }
        switch (m, c.weekday, c.weekdayOrdinal) {  // weekday 1 = Sunday
        case (5, 1, 2): return "母亲节"
        case (6, 1, 3): return "父亲节"
        case (11, 5, 4): return "感恩节"
        default: return nil
        }
    }

    /// Easter Sunday (Anonymous Gregorian computus).
    private static func easter(year: Int) -> (month: Int, day: Int) {
        let a = year % 19, b = year / 100, c = year % 100
        let d = b / 4, e = b % 4, f = (b + 8) / 25, g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4, k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        return ((h + l - 7 * m + 114) / 31, (h + l - 7 * m + 114) % 31 + 1)
    }

    // MARK: 二十四节气 (寿星公式, valid 2001–2100)

    // Two terms per month, Jan first; C coefficients for the 21st century.
    private static let termNames = [
        "小寒", "大寒", "立春", "雨水", "惊蛰", "春分", "清明", "谷雨",
        "立夏", "小满", "芒种", "夏至", "小暑", "大暑", "立秋", "处暑",
        "白露", "秋分", "寒露", "霜降", "立冬", "小雪", "大雪", "冬至",
    ]
    private static let termC: [Double] = [
        5.4055, 20.12, 3.87, 18.73, 5.63, 20.646, 4.81, 20.1,
        5.52, 21.04, 5.678, 21.37, 7.108, 22.83, 7.5, 23.13,
        7.646, 23.042, 8.318, 23.438, 7.438, 22.36, 7.18, 21.94,
    ]
    // 公式偏差年份修正: [termIndex * 10000 + year: dayOffset]
    private static let termFix: [Int: Int] = [
        0 * 10000 + 2019: -1,   // 小寒
        1 * 10000 + 2082: +1,   // 大寒
        3 * 10000 + 2026: -1,   // 雨水
        5 * 10000 + 2084: +1,   // 春分
        9 * 10000 + 2008: +1,   // 小满
        12 * 10000 + 2016: +1,  // 小暑
        14 * 10000 + 2002: +1,  // 立秋
        19 * 10000 + 2089: +1,  // 霜降
        20 * 10000 + 2089: +1,  // 立冬
        23 * 10000 + 2021: -1,  // 冬至
    ]

    private static func solarTerm(_ date: Date) -> String? {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        guard let year = c.year, let month = c.month, let day = c.day,
              (2001...2100).contains(year) else { return nil }
        let y = Double(year % 100)
        for i in [(month - 1) * 2, (month - 1) * 2 + 1] {
            // ponytail: 寿星公式 ±0 天 for 2001–2100 with the fix table above;
            // outside that century, no terms are shown.
            let leaps = (i < 2) ? (Int(y) - 1) / 4 : Int(y) / 4  // 小寒/大寒 straddle new year
            let termDay = Int(y * 0.2422 + termC[i]) - leaps + (termFix[i * 10000 + year] ?? 0)
            if termDay == day { return termNames[i] }
        }
        return nil
    }
}
