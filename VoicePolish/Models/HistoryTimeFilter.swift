import Foundation

enum HistoryTimeFilter: String, CaseIterable, Identifiable {
    case last24Hours = "last24h"
    case last7Days = "last7d"
    case last30Days = "last30d"
    case last3Months = "last3m"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .last24Hours: return "Last 24 Hours"
        case .last7Days: return "Last 7 Days"
        case .last30Days: return "Last 30 Days"
        case .last3Months: return "Last 3 Months"
        }
    }

    var cutoffDate: Date {
        let calendar = Calendar.current
        switch self {
        case .last24Hours: return calendar.date(byAdding: .hour, value: -24, to: Date())!
        case .last7Days: return calendar.date(byAdding: .day, value: -7, to: Date())!
        case .last30Days: return calendar.date(byAdding: .day, value: -30, to: Date())!
        case .last3Months: return calendar.date(byAdding: .month, value: -3, to: Date())!
        }
    }
}
