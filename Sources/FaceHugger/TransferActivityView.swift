import SwiftUI

struct TransferRetryView: View {
    let retry: TransferRetry
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 4) {
                Label(retry.reason.label, systemImage: "clock.arrow.circlepath").font(.system(size: 12, weight: .medium))
                Text("Request attempt \(retry.nextAttempt) of \(retry.request.maximumAttempts) · \(retry.remainingSeconds(at: context.date))s until retry")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct TransferActivityView: View {
    let activity: TransferLiveActivity
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let retry = activity.retry {
                TransferRetryView(retry: retry)
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(activity.phase?.label ?? "Working").font(.system(size: 12, weight: .medium))
                    Spacer(minLength: 8)
                    if let rate = activity.uploadBodyBytesPerSecond {
                        Text(rateText(rate)).font(.system(size: 12)).monospacedDigit()
                            .help("Measured from file and commit request bodies. Includes observed explicit retry sends and encoding; excludes headers and transport overhead.")
                    }
                }
                if let file = activity.currentFile {
                    Text(file).font(.system(size: 12)).lineLimit(1).truncationMode(.middle).help(file)
                }
            }
            if let transport = activity.transport {
                Text("\(ByteCountFormatter.string(fromByteCount: transport.requestBodyBytes, countStyle: .file)) in request bodies · \(transport.retryAttempts) request \(transport.retryAttempts == 1 ? "retry" : "retries")")
                    .font(.system(size: 11)).monospacedDigit().foregroundStyle(.secondary)
                    .help("Observed outgoing HTTP bodies, including metadata, file/commit content, and explicit retry attempts. Logical file progress is reported separately.")
            }
        }
    }
    private func rateText(_ rate: Double) -> String {
        if rate >= 1_000_000_000 { return String(format: "%.1f GB/s", rate / 1_000_000_000) }
        if rate >= 1_000_000 { return String(format: "%.1f MB/s", rate / 1_000_000) }
        if rate >= 1_000 { return String(format: "%.1f KB/s", rate / 1_000) }
        return String(format: "%.0f B/s", rate)
    }
}
