import SwiftUI

struct HistoryView: View {
    @Bindable var appState: AppState
    private var historyService: HistoryService { appState.historyService }

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
                            HistoryEntryCard(entry: entry, appState: appState)
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
        // Keep currentPage valid after deletes shrink the list.
        .onChange(of: historyService.entries.count) { _, _ in
            if currentPage > totalPages { currentPage = totalPages }
        }
    }

    private func copyAllTranscripts() {
        let text = filtered.map { $0.transcript }.filter { !$0.isEmpty }.joined(separator: "\n\n")
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
    @Bindable var appState: AppState
    @State private var showDeleteConfirm = false

    private var isRetrying: Bool { appState.retryingEntryId == entry.id }

    /// A retry is running on a different entry (retries are single-flight app-wide).
    private var otherRetryInFlight: Bool {
        appState.retryingEntryId != nil && appState.retryingEntryId != entry.id
    }

    /// Retry is possible when failed AND we can recover input: saved audio exists, or it
    /// was an LLM-stage failure and we still have the transcript.
    private var canRetry: Bool {
        entry.status == .failed &&
        (AudioStorageService.shared.exists(for: entry.id) ||
         (entry.failureStage == .llm && !entry.transcript.isEmpty))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Header: timestamp + status + actions
            HStack(spacing: 6) {
                Text(entry.timestamp, style: .date)
                Text(entry.timestamp, style: .time)
                if entry.status == .failed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text(entry.failureStage == .llm ? "LLM failed" : "Transcription failed")
                        .foregroundColor(.red)
                }
                Spacer()
                Button {
                    copyToClipboard(entry.transcript)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("Copy transcript")
                .buttonStyle(.borderless)
                .disabled(entry.transcript.isEmpty)

                Button {
                    copyToClipboard(entry.llmResponse ?? "")
                } label: {
                    Image(systemName: "doc.on.doc.fill")
                }
                .help("Copy LLM response")
                .buttonStyle(.borderless)
                .disabled(entry.llmResponse == nil || entry.llmResponse?.isEmpty == true)

                if showDeleteConfirm {
                    Button("Delete?") { performDelete() }
                        .font(.caption.bold()).foregroundColor(.red).buttonStyle(.borderless)
                    Button("No") { showDeleteConfirm = false }
                        .buttonStyle(.borderless)
                } else {
                    Button { showDeleteConfirm = true } label: {
                        Image(systemName: "trash")
                    }
                    .help("Delete entry and its audio")
                    .buttonStyle(.borderless)
                }
            }
            .font(.caption)
            .foregroundColor(.secondary)

            if entry.status == .failed {
                failedBody
            } else {
                successBody
            }
        }
        .padding(8)
        .background(Color(nsColor: .controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(entry.status == .failed ? Color.red.opacity(0.3) : Color.gray.opacity(0.2),
                        lineWidth: 1)
        )
    }

    @ViewBuilder
    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let msg = entry.errorMessage, !msg.isEmpty {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // LLM-stage failures still have a transcript worth showing.
            if !entry.transcript.isEmpty {
                Text(entry.transcript)
                    .font(.caption)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(Color.gray.opacity(0.08))
                    .cornerRadius(4)
            }
            HStack(spacing: 8) {
                if isRetrying {
                    ProgressView().controlSize(.small)
                    Text("Retrying…").font(.caption).foregroundColor(.secondary)
                    Spacer()
                    Button("Cancel") { appState.cancelRetry() }
                        .font(.caption)
                } else {
                    Button {
                        appState.retryHistoryEntry(id: entry.id)
                    } label: {
                        Label("Retry", systemImage: "arrow.clockwise").font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canRetry || otherRetryInFlight)

                    if !canRetry {
                        Text("Audio no longer available")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                }
            }
        }
    }

    @ViewBuilder
    private var successBody: some View {
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

    private func performDelete() {
        showDeleteConfirm = false
        if appState.retryingEntryId == entry.id { appState.cancelRetry() }
        appState.historyService.deleteEntry(id: entry.id)
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
