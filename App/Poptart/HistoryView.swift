import PoptartApplication
import SwiftUI

/// A thin projection of ``HistoryListModel``: Dictation Records newest first, each showing what
/// recognition heard, what Poptart delivered, how it ended, and how long it took.
struct HistoryView: View {
    let model: HistoryListModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(model.retentionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Refresh") { Task { await model.reload() } }
                Button("Clear History", role: .destructive) {
                    Task { await model.clearHistory() }
                }
            }
            if let message = model.message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
            if model.records.isEmpty {
                ContentUnavailableView(
                    "No Dictation Records",
                    systemImage: "clock",
                    description: Text("Dictations you make appear here for 30 days.")
                )
            } else {
                List(model.records) { record in
                    row(record)
                }
                .listStyle(.inset)
            }
        }
        .task { await model.reload() }
    }

    private func row(_ record: DictationRecordPresentation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(record.createdAt.formatted(date: .abbreviated, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(record.classification).font(.caption.weight(.semibold))
            }
            if record.deliveredText.isEmpty {
                Text("Nothing was delivered.").foregroundStyle(.secondary)
            } else {
                Text(record.deliveredText).textSelection(.enabled)
            }
            if record.hasRawTranscript {
                Text("Raw Transcript: \(record.rawTranscript)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 12) {
                Text(record.timings).font(.caption2).foregroundStyle(.secondary)
                if !record.destinationApplication.isEmpty {
                    Text(record.destinationApplication)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") { Task { await model.copyDeliveredText(record.id) } }
                    .disabled(!record.hasCopyableText)
                Button("Copy Raw") { Task { await model.copyRawTranscript(record.id) } }
                    .disabled(!record.hasRawTranscript)
                Button(role: .destructive) {
                    Task { await model.delete(record.id) }
                } label: {
                    Image(systemName: "trash")
                }
            }
            .buttonStyle(.borderless)
        }
        .padding(.vertical, 6)
    }
}
