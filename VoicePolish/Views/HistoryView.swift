import SwiftUI

struct HistoryView: View {
    let historyService = HistoryService.shared

    @State private var timeFilter: HistoryTimeFilter = .last24Hours
    @State private var currentPage: Int = 1
    @State private var showClearConfirmation = false

    private let itemsPerPage = 8

    private var filtered: [HistoryEntry] {
        historyService.getEntries(filter: timeFilter)
    }

    private var totalPages: Int {
        max(1, Int(ceil(Double(filtered.count) / Double(itemsPerPage))))
    }

    private var pageEntries: [HistoryEntry] {
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

                Text("\(filtered.count) entries")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Bulk copy buttons
            HStack(spacing: 8) {
                Button {
                    copyAllTranscripts()
                } label: {
                    Label("Copy All Transcripts", systemImage: "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(filtered.isEmpty)

                Button {
                    copyAllLLMOutputs()
                } label: {
                    Label("Copy All LLM Outputs", systemImage: "doc.on.doc.fill")
                        .font(.caption)
                }
                .buttonStyle(.bordered)
                .disabled(filtered.isEmpty)

                Spacer()

                if !filtered.isEmpty {
                    if showClearConfirmation {
                        HStack(spacing: 4) {
                            Text("Delete all?")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Button("Yes") {
                                historyService.clearAll()
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
                    Image(systemName: "clock.arrow.circlepath")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No history entries")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Completed recordings will appear here.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(pageEntries) { entry in
                            HistoryEntryCard(entry: entry)
                        }
                    }
                }
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

    private func copyAllTranscripts() {
        let text = filtered.map { $0.transcript }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func copyAllLLMOutputs() {
        let text = filtered.compactMap { $0.llmResponse }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

struct HistoryEntryCard: View {
    let entry: HistoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Timestamp + copy buttons
            HStack {
                Text(entry.timestamp, style: .date)
                Text(entry.timestamp, style: .time)
                Spacer()
                Button {
                    copyToClipboard(entry.transcript)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy transcript")
                .buttonStyle(.borderless)

                Button {
                    copyToClipboard(entry.llmResponse ?? "")
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                }
                .help("Copy LLM response")
                .buttonStyle(.borderless)
                .disabled(entry.llmResponse == nil || entry.llmResponse?.isEmpty == true)
            }
            .font(.caption)
            .foregroundColor(.secondary)

            // Side-by-side: transcript | LLM output
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Transcript")
                        .font(.caption2.bold())
                        .foregroundColor(.secondary)
                    Text(entry.transcript)
                        .font(.caption)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(6)
                .background(Color.gray.opacity(0.08))
                .cornerRadius(4)

                if let llmResponse = entry.llmResponse, !llmResponse.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("LLM Output")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Text(llmResponse)
                            .font(.caption)
                            .lineLimit(4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(6)
                    .background(Color.blue.opacity(0.06))
                    .cornerRadius(4)
                } else {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Transcript Only")
                            .font(.caption2.bold())
                            .foregroundColor(.secondary)
                        Text("No LLM processing")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(6)
                    .background(Color.gray.opacity(0.04))
                    .cornerRadius(4)
                }
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.gray.opacity(0.2), lineWidth: 1)
        )
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
