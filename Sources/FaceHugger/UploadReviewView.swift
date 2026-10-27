import SwiftUI

struct UploadReviewView: View {
    @Bindable var workspace: UploadReviewWorkspace
    let onApprove: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review upload").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text(workspace.job.source).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                Label(workspace.job.repo.name + (workspace.job.destination.isEmpty ? " /" : " /" + workspace.job.destination), systemImage: "arrow.right")
                    .font(.headline).textSelection(.enabled)
                Text(workspace.job.repo.isPrivate ? "Private repository" : "Public repository")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if workspace.building {
                VStack(alignment: .leading, spacing: 12) {
                    ProgressView(workspace.phase?.label ?? "Preparing review").controlSize(.small)
                    Text(workspace.status).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    if let retry = workspace.retry { TransferRetryView(retry: retry) }
                    Text("Reading local files for hashes and comparing repository metadata. No file contents are uploaded during review.")
                        .font(.callout).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if let plan = workspace.plan {
                HStack(alignment: .top, spacing: 24) {
                    ForEach(PlannedFileAction.allCases, id: \.self) { action in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(action.label).font(.caption).foregroundStyle(.secondary)
                            Text("\(plan.summary.counts[action] ?? 0)").font(.title3.monospacedDigit())
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Candidate upload content: \(ByteCountFormatter.string(fromByteCount: plan.summary.candidateBytes, countStyle: .file))")
                        .font(.callout.weight(.medium))
                    Text("Actual transfer size depends on service reuse and repository ignore rules. Identical files are verified and skipped.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Reviewed for \(plan.account) at \(plan.originalHead.map { String($0.prefix(12)) } ?? "an unavailable revision")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let reason = plan.blockedReason {
                    Label(reason, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.orange)
                } else if (plan.summary.counts[.conflict] ?? 0) > 0 {
                    Label("Resolve file/folder conflicts or choose another destination before uploading.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Picker("Show", selection: $workspace.filter) {
                        Text("All files").tag(PlannedFileAction?.none)
                        ForEach(PlannedFileAction.allCases, id: \.self) { action in Text(action.label).tag(Optional(action)) }
                    }.frame(width: 240)
                    Spacer()
                    Text("\(workspace.filteredCount) files").font(.caption).foregroundStyle(.secondary)
                }
                Table(workspace.rows) {
                    TableColumn("File") { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.path).lineLimit(1).help(row.path)
                            if let reason = row.reason { Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                    TableColumn("Action") { row in Text(row.action.label) }.width(140)
                    TableColumn("Size") { row in Text(ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file)) }.width(100)
                }.frame(minHeight: 160)
                HStack {
                    Button("Previous") { workspace.offset = max(0, workspace.offset - 100); workspace.loadPage() }
                        .disabled(workspace.offset == 0)
                    Text(workspace.rows.isEmpty ? "No matching files" : "\(workspace.offset + 1)–\(workspace.offset + workspace.rows.count) of \(workspace.filteredCount)")
                        .font(.caption).monospacedDigit()
                    Button("Next") { workspace.offset += 100; workspace.loadPage() }
                        .disabled(workspace.offset + workspace.rows.count >= workspace.filteredCount)
                    Spacer()
                }
                if (plan.summary.counts[.needsComparison] ?? 0) > 0 {
                    Toggle("Include files whose remote contents could not be compared; their remote paths may be replaced.", isOn: $workspace.allowUnknownComparisons)
                        .font(.callout)
                }
            } else { Spacer() }
            if let error = workspace.error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            HStack {
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Spacer()
                Button(workspace.startWhenApproved ? "Upload reviewed files" : "Add reviewed upload to queue", action: onApprove)
                    .buttonStyle(.borderedProminent).disabled(!workspace.canApprove).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 860, height: 720)
        .interactiveDismissDisabled()
        .onChange(of: workspace.filter) { _, _ in workspace.offset = 0; workspace.loadPage() }
    }
}
