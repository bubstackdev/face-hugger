import AppKit
import SwiftUI

/// A compact, persistent activity surface. Selecting history never hides the
/// active transfer: the header retains a direct link and stop control.
struct TransferShelf: View {
    @Bindable var model: AppModel
    @State private var showTransfers = false
    @State private var showLog = false
    @State private var showHistory = false
    @State private var selectedReceipt: TransferReceipt?
    private let slate = Color(red: 0.11, green: 0.145, blue: 0.18)
    private let muted = Color(red: 0.73, green: 0.77, blue: 0.81)
    private let gold = Color(red: 0.965, green: 0.784, blue: 0.271)
    private let activityBlue = Color(red: 0.525, green: 0.776, blue: 0.933)

    private var displayedJob: UploadJob? {
        model.selectedJob ?? model.activeJob ?? model.jobs.last
    }
    private var listedJobs: [UploadJob] {
        model.jobs.filter { $0.state != .completed }
    }
    private func recovery(_ job: UploadJob) -> UploadRecoveryHint {
        guard job.state != .running && job.state != .completed else { return .other }
        let access: FolderAccess
        do { access = try FolderAccess.restore(path: job.source, bookmark: job.sourceBookmark) }
        catch { return .missingSource }
        defer { access.close() }
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: access.url.path, isDirectory: &isDirectory) && isDirectory.boolValue
        return UploadRecoveryHint.classify(message: job.message, sourceExists: exists)
    }

    private func resumeLabel(_ job: UploadJob) -> String {
        job.state == .queued ? "Start upload" : job.state == .failed ? "Retry upload" : "Resume upload"
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Text(displayedJob.map(headline) ?? "No transfers yet")
                    .font(.system(size: 14, weight: .medium))
                Spacer(minLength: 10)
                if let active = model.activeJob, active.id != displayedJob?.id {
                    Button {
                        model.selectedJobID = active.id
                    } label: {
                        Label("Uploading \(active.title)", systemImage: "arrow.up.circle.fill")
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain).foregroundStyle(activityBlue)
                    .help("Show the active upload")
                    Button("Stop", systemImage: "stop.circle") { model.stop() }
                        .help("Stop the active upload and pause the queue")
                }
                if !model.jobs.isEmpty || !model.transferReceipts.isEmpty {
                    Button {
                        if model.selectedJobID == nil { model.selectedJobID = displayedJob?.id }
                        showHistory = displayedJob == nil || displayedJob?.state == .completed
                        showTransfers.toggle()
                    } label: {
                        Label("Transfers", systemImage: "list.bullet")
                    }
                    .popover(isPresented: $showTransfers, arrowEdge: .top) { transferList }
                    .accessibilityHint("Open upload queue and saved transfer receipts")
                }
            }
            .frame(height: 64)
            .padding(.horizontal, 28)
            if let job = displayedJob {
                Rectangle().fill(.white.opacity(0.12)).frame(height: 1)
                HStack(alignment: .top, spacing: 26) {
                    route(job).frame(width: 230, alignment: .leading)
                    activity(job).frame(maxWidth: .infinity, alignment: .leading)
                    actions(job).frame(width: 162, alignment: .trailing)
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 20)
                .frame(minHeight: 142, alignment: .top)
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(.white)
        .background(slate)
        .environment(\.colorScheme, .dark)
        .sheet(isPresented: $showLog) { logSheet }
        .sheet(item: $selectedReceipt) { receipt in TransferReceiptView(receipt: receipt) }
    }

    private func headline(_ job: UploadJob) -> String {
        switch job.state {
        case .running: "Uploading"
        case .interrupted: "Upload interrupted"
        case .stopped: "Upload stopped"
        case .completed: "Upload complete"
        case .failed: "Upload needs attention"
        case .queued: "Ready to upload"
        }
    }

    private func route(_ job: UploadJob) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(job.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            Text(job.source).foregroundStyle(muted).lineLimit(1).truncationMode(.middle)
                .help(job.source).textSelection(.enabled).id(job.source)
            Label(job.repo.name + (job.destination.isEmpty ? "" : "/" + job.destination), systemImage: "arrow.right")
                .foregroundStyle(muted).lineLimit(2).textSelection(.enabled)
                .help(job.repo.name + "/" + job.destination)
            if let finished = job.finishedAt, job.state == .completed {
                Text(finished.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(muted)
            }
        }
    }

    @ViewBuilder
    private func activity(_ job: UploadJob) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if job.state == .running, let activity = model.transferActivity[job.id] {
                TransferActivityView(activity: activity)
            }
            activityDetails(job)
        }
    }

    @ViewBuilder
    private func activityDetails(_ job: UploadJob) -> some View {
        let hint = recovery(job)
        if job.state == .completed {
            let recorded = model.transferReceipts.first { $0.jobID == job.id && $0.outcome == .completed }?.progress
            let allIgnored = (recorded?.total ?? 0) > 0 && recorded?.ignoredFiles == recorded?.total
            VStack(alignment: .leading, spacing: 9) {
                Label(allIgnored ? "No files uploaded; repository rules excluded them" : "Files confirmed on Hugging Face", systemImage: allIgnored ? "minus.circle" : "checkmark.circle.fill")
                    .foregroundStyle(Color(red: 0.545, green: 0.835, blue: 0.639))
                Text(job.message).foregroundStyle(muted).textSelection(.enabled)
            }
        } else if job.state == .failed || (job.state != .running && hint == .missingSource) {
            VStack(alignment: .leading, spacing: 9) {
                Text(job.message).foregroundStyle(.white).textSelection(.enabled)
                    .lineLimit(3).help(job.message)
                Text(hint.guidance).foregroundStyle(muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let progress = model.progress[job.id], job.state != .interrupted {
            VStack(alignment: .leading, spacing: 10) {
                Text(job.state == .running ? "File progress" : "Last reported this session")
                    .foregroundStyle(muted)
                HStack(alignment: .top, spacing: 22) {
                    counter("Prepared", "\(progress.checked) / \(progress.total)")
                    counter("Uploaded or reused", "\(progress.uploaded) / \(progress.uploadTotal)", color: activityBlue)
                    counter("Confirmed remote", "\(progress.committed)")
                }.monospacedDigit()
                Text("\(progress.transferred) of file content reported sent · \(progress.commits) commits")
                    .foregroundStyle(muted).monospacedDigit()
                if job.state != .running {
                    Text("Committed files remain remote. Resume checks the source again.")
                        .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 9) {
                if job.state == .running {
                    if model.transferActivity[job.id] == nil {
                        HStack(spacing: 9) {
                            ProgressView().controlSize(.small)
                            Text(job.message).foregroundStyle(muted)
                        }
                    }
                } else {
                    Text(job.message).foregroundStyle(muted).textSelection(.enabled)
                }
                if job.state == .interrupted {
                    Text("Open the receipt for the last recorded results. Resume checks local and remote files again; confirmed commits remain on Hugging Face.")
                        .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                } else if job.state != .queued && job.state != .running {
                    Text("Resume checks the source again. Keep its files unchanged to continue the same upload.")
                        .foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func counter(_ name: String, _ value: String, color: Color = .white) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(name).foregroundStyle(muted).fixedSize()
            Text(value).font(.system(size: 14, weight: .medium)).foregroundStyle(color)
        }.accessibilityElement(children: .combine)
    }

    private func actions(_ job: UploadJob) -> some View {
        let hint = recovery(job)
        return VStack(alignment: .trailing, spacing: 12) {
            if job.state == .running {
                Button("Stop upload", systemImage: "stop.fill") { model.stop() }
                    .buttonStyle(.borderedProminent).tint(gold).foregroundStyle(slate)
            } else if job.state != .completed {
                Button("Review again…", systemImage: "doc.text.magnifyingglass") { model.reviewUpload(job.id) }
                    .buttonStyle(.plain).foregroundStyle(gold)
                if hint == .missingSource {
                    Button("Locate folder…", systemImage: "folder") { model.locateSource(for: job.id) }
                        .buttonStyle(.borderedProminent).tint(gold).foregroundStyle(slate)
                        .help("Locate the original source folder; upload will not start automatically")
                } else if job.state == .failed && hint == .authentication {
                    Button("Account settings…", systemImage: "person.crop.circle") { model.showSettings = true }
                        .buttonStyle(.plain).foregroundStyle(gold)
                }
                Button(resumeLabel(job), systemImage: "play.fill") { model.resume(job.id) }
                    .buttonStyle(.borderedProminent).tint(gold).foregroundStyle(slate)
                    .disabled(hint == .missingSource)
                    .help(model.activeJob == nil ? "Start this upload" : "Run this upload after the active transfer")
            }
            Button("Open on Hugging Face", systemImage: "arrow.up.right.square") { NSWorkspace.shared.open(job.repo.url) }
                .buttonStyle(.plain).foregroundStyle(gold)
            if let receipt = model.transferReceipts.first(where: { $0.jobID == job.id && $0.outcome != .running }) {
                Button("Receipt", systemImage: "doc.text") { selectedReceipt = receipt }
                    .buttonStyle(.plain).foregroundStyle(gold)
            }
            Button("Activity log", systemImage: "text.alignleft") { showLog = true }
                .buttonStyle(.plain).foregroundStyle(gold)
                .disabled(model.logs[job.id]?.isEmpty != false)
                .help(model.logs[job.id]?.isEmpty == false ? "View this session’s activity log" : "No log is available for this upload in this session")
        }
    }

    private var transferList: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Transfers").font(.headline)
                Spacer()
                if model.activeJob == nil && model.jobs.contains(where: { $0.state == .queued }) {
                    Button("Start queue", systemImage: "play.fill") { model.startQueue() }
                }
            }
            Picker("Transfer list", selection: $showHistory) {
                Text("Queue").tag(false)
                Text("History").tag(true)
            }.pickerStyle(.segmented)
            if showHistory {
                TransferHistoryView(model: model)
            } else if listedJobs.isEmpty {
                ContentUnavailableView(showHistory ? "No completed uploads" : "Queue is empty", systemImage: showHistory ? "clock" : "tray")
                    .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                List(selection: $model.selectedJobID) {
                    ForEach(listedJobs) { job in
                        HStack(spacing: 12) {
                            Image(systemName: job.state == .running ? "arrow.up.circle.fill" : job.state == .completed ? "checkmark.circle" : "folder")
                            VStack(alignment: .leading, spacing: 4) {
                                Text(job.title).font(.system(size: 13, weight: .medium))
                                Text(job.repo.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            Text(job.state.label).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        .tag(job.id)
                        .contextMenu {
                            if job.state != .running && job.state != .completed {
                                Button("Review upload…") { model.reviewUpload(job.id) }
                                Button(resumeLabel(job)) { model.resume(job.id) }
                                    .disabled(recovery(job) == .missingSource)
                                if recovery(job) == .missingSource {
                                    Button("Locate source folder…") { model.locateSource(for: job.id) }
                                }
                                if job.state == .failed && recovery(job) == .authentication {
                                    Button("Account settings…") { model.showSettings = true }
                                }
                            }
                            if job.state == .running { Button("Stop upload") { model.stop() } }
                            Button("Reveal in Finder") { NSWorkspace.shared.selectFile(job.source, inFileViewerRootedAtPath: "") }
                            Button("Open on Hugging Face") { NSWorkspace.shared.open(job.repo.url) }
                            if job.state != .running { Button("Remove from list", role: .destructive) { model.remove(job.id) } }
                        }
                    }
                    .onMove { offsets, destination in
                        var ordered = listedJobs
                        ordered.move(fromOffsets: offsets, toOffset: destination)
                        let ids = Set(ordered.map(\.id))
                        var iterator = ordered.makeIterator()
                        model.jobs = model.jobs.map { ids.contains($0.id) ? iterator.next()! : $0 }
                        model.persist()
                    }
                }.frame(height: 240)
            }
            HStack {
                if !showHistory, let selected = model.selectedJob, selected.state != .running {
                    Button("Remove from list", role: .destructive) { model.remove(selected.id) }
                }
                Spacer()
                Button("Done") { showTransfers = false }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(18).frame(width: 460)
    }

    private var logSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Activity log · \(displayedJob?.title ?? "Upload")").font(.headline)
            Text("This session only. Logs are not retained after quitting.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ScrollView {
                Text(displayedJob.flatMap { model.logs[$0.id] } ?? "No log is available in this session.")
                    .font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack { Spacer(); Button("Done") { showLog = false }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 680, height: 460)
    }
}
