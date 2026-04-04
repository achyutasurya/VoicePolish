import SwiftUI

struct ErrorsView: View {
    let errorService = ErrorService.shared

    @State private var timeFilter: HistoryTimeFilter = .last24Hours
    @State private var currentPage: Int = 1
    @State private var showClearConfirmation = false

    private let itemsPerPage = 8

    private var filtered: [ErrorEntry] {
        errorService.getEntries(filter: timeFilter)
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(filtered.count) / Double(itemsPerPage))))
    }

    private var pageEntries: [ErrorEntry] {
        Array(filtered.dropFirst((currentPage - 1) * itemsPerPage).prefix(itemsPerPage))
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

                Text("\(filtered.count) errors")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Clear All
            HStack {
                Spacer()
                if !filtered.isEmpty {
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
            if pageEntries.isEmpty {
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
                    }
                }
            }

            // Pagination
            if totalPages > 1 {
                HStack {
                    Spacer()
                    ForEach(1...totalPages, id: \.self) { page in
                        Button("\(page)") {
                            currentPage = page
                        }
                        .buttonStyle(.bordered)
                        .tint(page == currentPage ? .blue : .secondary)
                        .font(.caption)
                    }
                    Spacer()
                }
            }
        }
        .padding()
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
        if let details = entry.details, !details.isEmpty {
            text += "\n\nDetails:\n\(details)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
