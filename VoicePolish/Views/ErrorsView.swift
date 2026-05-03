import SwiftUI

struct ErrorsView: View {
    let errorService = ErrorService.shared
    let historyService = HistoryService.shared

    @State private var timeFilter: HistoryTimeFilter = .last24Hours
    @State private var currentPage: Int = 1
    @State private var showClearConfirmation = false
    @State private var showTransient = false

    private let itemsPerPage = 8

    private var split: (actionable: [ErrorEntry], transientGroups: [TransientGroup]) {
        errorService.getDisplayEntries(filter: timeFilter)
    }

    private var actionable: [ErrorEntry] { split.actionable }
    private var transientGroups: [TransientGroup] { split.transientGroups }
    private var transientCountInWindow: Int {
        transientGroups.reduce(0) { $0 + $1.count }
    }
    /// Successful pipeline runs in the same time window. Used to derive the
    /// success-rate footer (v0.3.24, P2 cross-cutting C metrics rollup).
    private var successfulRecordingsInWindow: Int {
        historyService.getEntries(filter: timeFilter).count
    }
    private var totalEventsInWindow: Int {
        successfulRecordingsInWindow + actionable.count + transientCountInWindow
    }
    private var successRatePercent: Int {
        guard totalEventsInWindow > 0 else { return 100 }
        return Int(round(Double(successfulRecordingsInWindow) / Double(totalEventsInWindow) * 100))
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(actionable.count) / Double(itemsPerPage))))
    }

    private var pageEntries: [ErrorEntry] {
        Array(actionable.dropFirst((currentPage - 1) * itemsPerPage).prefix(itemsPerPage))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Filter row
            HStack {
                Picker("", selection: $timeFilter) {
                    ForEach(HistoryTimeFilter.allCases) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .onChange(of: timeFilter) { _, _ in currentPage = 1 }

                Spacer()

                Text("\(actionable.count) actionable")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Clear All
            HStack {
                Spacer()
                if !actionable.isEmpty || !transientGroups.isEmpty {
                    if showClearConfirmation {
                        HStack(spacing: 4) {
                            Text("Delete all errors?")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Yes") {
                                errorService.clearAll()
                                currentPage = 1
                                showClearConfirmation = false
                            }
                            .font(.caption.bold())
                            .foregroundColor(.red)
                            Button("No") {
                                showClearConfirmation = false
                            }
                            .font(.caption)
                        }
                    } else {
                        Button("Clear All", role: .destructive) {
                            showClearConfirmation = true
                        }
                        .font(.caption)
                    }
                }
            }

            Divider()

            // Entries list
            if pageEntries.isEmpty && transientGroups.isEmpty {
                VStack(spacing: 8) {
                    Spacer()
                    Image(systemName: "checkmark.circle")
                        .font(.largeTitle)
                        .foregroundColor(.green)
                    Text("No errors")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Everything is running smoothly.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(pageEntries) { entry in
                            ErrorEntryCard(entry: entry)
                        }

                        if !transientGroups.isEmpty {
                            TransientSummaryBlock(
                                groups: transientGroups,
                                totalCount: transientCountInWindow,
                                expanded: $showTransient
                            )
                        }
                    }
                }
            }

            // P2 cross-cutting C (v0.3.24): metrics rollup footer.
            // Derived live from HistoryService + ErrorService for the active
            // time filter — no separate metrics.json needed.
            if totalEventsInWindow > 0 {
                HStack(spacing: 12) {
                    Label("\(successfulRecordingsInWindow) recordings", systemImage: "waveform")
                    Label("\(actionable.count) actionable", systemImage: "exclamationmark.triangle")
                    Label("\(transientCountInWindow) transient", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    Text("\(successRatePercent)% success")
                        .foregroundColor(successRatePercent >= 95 ? .green : .orange)
                }
                .font(.caption2)
                .foregroundColor(.secondary)
            }

            // Pagination
            if totalPages > 1 {
                HStack(spacing: 12) {
                    Spacer()

                    Button {
                        currentPage = max(1, currentPage - 1)
                    } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentPage <= 1)

                    Text("Page \(currentPage) of \(totalPages)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .frame(minWidth: 100)

                    Button {
                        currentPage = min(totalPages, currentPage + 1)
                    } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.bordered)
                    .disabled(currentPage >= totalPages)

                    Spacer()
                }
            }
        }
        .padding()
        .frame(maxWidth: 520)
    }
}

struct ErrorEntryCard: View {
    let entry: ErrorEntry
    @State private var isExpanded = false

    private var severityColor: Color {
        switch entry.severity {
        case .warning: return .yellow
        case .error: return .red
        case .critical: return .purple
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                // Severity indicator
                Circle()
                    .fill(severityColor)
                    .frame(width: 8, height: 8)

                // Source badge
                Text(entry.source.rawValue)
                    .font(.caption2.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(severityColor.opacity(0.15))
                    .cornerRadius(4)

                Text(entry.severity.rawValue)
                    .font(.caption2)
                    .foregroundColor(severityColor)

                Text(entry.timestamp, style: .date)
                Text(entry.timestamp, style: .time)

                Spacer()

                // Copy button
                Button {
                    copyErrorDetails()
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help("Copy error details")
            }
            .font(.caption)
            .foregroundColor(.secondary)

            Text(entry.message)
                .font(.caption)
                .lineLimit(isExpanded ? nil : 2)

            if let requestId = entry.requestId, !requestId.isEmpty {
                Text("Request ID: \(requestId)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
            }

            if let details = entry.details, !details.isEmpty {
                Button(isExpanded ? "Hide Details" : "Show Details") {
                    withAnimation { isExpanded.toggle() }
                }
                .font(.caption2)

                if isExpanded {
                    Text(details)
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                        .padding(6)
                        .background(Color.gray.opacity(0.08))
                        .cornerRadius(4)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(severityColor.opacity(0.3), lineWidth: 1)
        )
    }

    private func copyErrorDetails() {
        var text = "[\(entry.severity.rawValue)] [\(entry.source.rawValue)] \(entry.message)"
        if let requestId = entry.requestId, !requestId.isEmpty {
            text += "\nRequest ID: \(requestId)"
        }
        if let details = entry.details, !details.isEmpty {
            text += "\n\nDetails:\n\(details)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct TransientSummaryBlock: View {
    let groups: [TransientGroup]
    let totalCount: Int
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Transient (\(totalCount))")
                        .font(.caption.bold())
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(expanded ? "Hide" : "Show")
                        .font(.caption2)
                        .foregroundColor(.accentColor)
                }
            }
            .buttonStyle(.borderless)

            if expanded {
                ForEach(groups) { group in
                    TransientGroupRow(group: group)
                }
            }
        }
        .padding(8)
        .background(Color.gray.opacity(0.06))
        .cornerRadius(8)
    }
}

private struct TransientGroupRow: View {
    let group: TransientGroup

    private var severityColor: Color {
        switch group.severity {
        case .warning: return .yellow
        case .error: return .orange
        case .critical: return .purple
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(severityColor.opacity(0.7))
                .frame(width: 6, height: 6)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(group.source.rawValue)
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Text("·")
                        .foregroundColor(.secondary)
                    Text(group.title)
                        .font(.caption)
                        .lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text("\(group.count)×")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                    Text("last:")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(group.latest, style: .relative)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
        .padding(.vertical, 2)
    }
}
