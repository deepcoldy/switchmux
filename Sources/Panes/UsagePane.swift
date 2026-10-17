import AppKit
import SwiftUI

enum UsageRange: String, CaseIterable, Identifiable {
    case today, last7, last30, last90, last180, year, all
    var id: String { rawValue }
    var label: String {
        switch self {
        case .today: return "今天"
        case .last7: return "最近 7 天"
        case .last30: return "最近 30 天"
        case .last90: return "最近 3 个月"
        case .last180: return "最近 6 个月"
        case .year: return "过去一年"
        case .all: return "全部"
        }
    }
    var days: Int? {
        switch self {
        case .today: return 1
        case .last7: return 7
        case .last30: return 30
        case .last90: return 90
        case .last180: return 180
        case .year: return 365
        case .all: return nil
        }
    }
}

final class UsagePaneModel: ObservableObject {
    @Published var range: UsageRange = .last7
}

struct UsagePane: View {
    @EnvironmentObject var settings: SettingsStore
    @StateObject private var model = UsagePaneModel()

    private var range: UsageRange {
        get { model.range }
        set { model.range = newValue }
    }

    private var calendar: Calendar { Calendar(identifier: .gregorian) }

    /// Aggregated counts per day, oldest first.
    private var dailyCounts: [(day: Date, count: Int)] {
        var result: [(Date, Int)] = []
        if range == .all {
            let items = settings.usageByDay.map { (SettingsStore.dayFormatter.date(from: $0.key) ?? Date(), $0.value) }
            return items.sorted { $0.0 < $1.0 }.map { ($0.0, $0.1) }
        }
        guard let days = range.days else { return [] }
        let today = calendar.startOfDay(for: Date())
        for offset in stride(from: days - 1, through: 0, by: -1) {
            let day = calendar.date(byAdding: .day, value: -offset, to: today)!
            let key = SettingsStore.dayFormatter.string(from: day)
            result.append((day, settings.usageByDay[key] ?? 0))
        }
        return result.map { ($0.0, $0.1) }
    }

    private var total: Int { dailyCounts.reduce(0) { $0 + $1.count } }
    private var average: Int {
        guard !dailyCounts.isEmpty else { return 0 }
        return total / dailyCounts.count
    }
    private var maxCount: Int { max(dailyCounts.map(\.count).max() ?? 1, 1) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Picker("", selection: $model.range) {
                    ForEach(UsageRange.allCases) { Text($0.label).tag($0) }
                }
                .frame(width: 160)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)

            HStack(spacing: 32) {
                stat(title: "总次数", value: "\(total)")
                stat(title: "日均", value: "\(average)")
                stat(title: "累计", value: "\(settings.usageCount)")
            }
            .padding(.horizontal, 20)

            GeometryReader { geo in
                chart(width: geo.size.width)
            }
            .padding(.horizontal, 20)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(NSColor.windowBackgroundColor))
    }

    private func stat(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func chart(width: CGFloat) -> some View {
        let data = dailyCounts
        let count = max(data.count, 1)
        let spacing: CGFloat = data.count > 60 ? 1 : 3
        let barWidth = max(1, (width - spacing * CGFloat(count - 1)) / CGFloat(count))
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(data.enumerated()), id: \.offset) { _, entry in
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: min(4, barWidth / 3))
                        .fill(entry.count > 0
                              ? Color.accentColor
                              : Color.primary.opacity(0.12))
                        .frame(width: barWidth,
                               height: max(CGFloat(entry.count) / CGFloat(maxCount) * 220,
                                           entry.count > 0 ? 3 : 2))
                }
                .frame(height: 220, alignment: .bottom)
            }
        }
    }
}
