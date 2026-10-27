import AppKit
import SwiftUI
import UserNotifications

@MainActor @Observable
final class AppModel {
    var jobs: [UploadJob] = []
    var repos: [HubRepo] = []
    var identity: HubIdentity?
    var selectedOwner = ""
    var entries: [RemoteEntry] = []
    var remotePath = "" { didSet { validateActivePairing() } }
    var currentRepo: HubRepo? { didSet { validateActivePairing() } }
    var loading = false
    var accountBusy = false
    var error: String?
    var datasetCard: DatasetCardWorkspace?
    var showSettings = false
    var showUpload = false
    var showCreateRepo = false
    var draftSource = "" { didSet { validateActivePairing() } }
    private var draftSourceBookmark: Data?
    private var workspaceFolderAccess: FolderAccess?
    var draftIncludes: [String] = [] { didSet { validateActivePairing() } }
    var draftExcludes = [".DS_Store", "**/.DS_Store"] { didSet { validateActivePairing() } }
    var staging: StagingResult?
    var comparison: RemoteComparison?
    var comparing = false
    var comparisonError: String?
    var browseError: String?
    private var comparisonGeneration = UUID()
    private var comparisonProcess: NativeOperation?
    var scanning = false
    var scanError: String?
    var pairings: [SavedPairing] = []
    private var activePairing: ActivePairing?
    private var workspaceGeneration = UUID()
    private var replacingWorkspace = false
    var pendingFolders: [FolderEntry] = []
    var activePairingID: UUID? {
        guard let activePairing, pairings.contains(where: { $0.id == activePairing.id }), pairingMatches(activePairing) else { return nil }
        return activePairing.id
    }
    private func pairingMatches(_ pairing: ActivePairing) -> Bool {
        pairing.matches(folder: try? PairingFolderIdentity(url: URL(fileURLWithPath: draftSource)), repo: currentRepo,
                        destination: remotePath, includes: draftIncludes, excludes: draftExcludes)
    }
    private func validateActivePairing() {
        if let activePairing, !pairingMatches(activePairing) { self.activePairing = nil }
    }
    var uploadReview: UploadReviewWorkspace?
    var submitting: Bool { uploadReview != nil }
    private var scanGeneration = UUID()
    private var scanProcess: NativeOperation?
    private let pairingArchive = PairingArchive(url: AppPaths.support.appendingPathComponent("pairings.json"))
    var selectedJobID: UUID?
    var sidebar = "uploads"
    var runtimeReady = AppPaths.runtimeReady
    var logs: [UUID: String] = [:]
    var progress: [UUID: UploadProgress] = [:]
    var transferActivity: [UUID: TransferLiveActivity] = [:]
    var transferReceipts: [TransferReceipt] = []
    private var transferHistory: TransferHistoryStore?
    private var activeAttemptID: UUID?
    private var receivedSequence: UInt64 = 0
    var keepAwake = true
    private var queueControl = UploadQueueControl()
    private var token: String?
    private var runner: NativeOperation?
    private var activity: NSObjectProtocol?
    private var browseGeneration = UUID()
    private var selectionGeneration = UUID()
    private var repoRefreshGeneration = UUID()
    private var newlyCreatedRepos: [String: (repo: HubRepo, date: Date)] = [:]
    private let archive = QueueArchive(url: AppPaths.support.appendingPathComponent("queue.json"))
    var activeJob: UploadJob? { jobs.first { $0.state == .running } }
    var selectedJob: UploadJob? { jobs.first { $0.id == selectedJobID } }
    var hasExistingCredentials: Bool { token != nil }

    init() {
        token = CredentialStore.read()
        do { pairings = try pairingArchive.load() } catch { self.error = "Could not load saved pairings: \(error.localizedDescription)" }
        do { jobs = try archive.load() } catch { self.error = "Could not read the saved upload queue: \(error.localizedDescription)" }
        do {
            transferHistory = try TransferHistoryStore(
                archive: TransferHistoryArchive(url: AppPaths.support.appendingPathComponent("transfer-history.json")),
                legacyJobs: jobs)
            transferReceipts = transferHistory?.receipts ?? []
        } catch { self.error = "Could not open transfer history. Uploads are paused to preserve existing records. \(error.localizedDescription)" }
    }
    func persist() {
        do { try archive.save(jobs) } catch { self.error = "Could not save the queue: \(error.localizedDescription)" }
    }
    func connect(token entered: String? = nil) async {
        guard runtimeReady else { showSettings = true; return }
        accountBusy = true; defer { accountBusy = false }
        do {
            let candidate = entered?.trimmingCharacters(in: .whitespacesAndNewlines) ?? token
            let result: HubIdentity = try await HubService.request(["whoami"], token: candidate)
            if let entered, !entered.isEmpty { try CredentialStore.save(candidate ?? ""); token = candidate }
            identity = result
            selectedOwner = result.name
            await refreshRepos()
        } catch { self.error = error.localizedDescription }
    }
    func disconnect() {
        guard activeJob == nil else { error = "Stop the active upload before signing out."; return }
        cancelUploadReview()
        do { try CredentialStore.save(""); selectionGeneration = UUID(); browseGeneration = UUID(); repoRefreshGeneration = UUID(); loading = false; token = nil; identity = nil; repos = []; entries = []; currentRepo = nil; invalidateComparison() }
        catch { self.error = error.localizedDescription }
    }
    func refreshRepos(owner: String? = nil) async {
        guard let owner = owner ?? (selectedOwner.isEmpty ? identity?.name : selectedOwner) else { return }
        let generation = UUID(); repoRefreshGeneration = generation
        loading = true; defer { if repoRefreshGeneration == generation { loading = false } }
        do {
            let result: [RepoResponse] = try await HubService.request(["repos", "--owner", owner, "--stream"], token: token)
            guard repoRefreshGeneration == generation else { return }
            var received = result.map(\.repo)
            let ids = Set(received.map(\.id))
            // HF's search-backed listings can lag behind successful creation.
            newlyCreatedRepos = newlyCreatedRepos.filter { !ids.contains($0.key) && Date().timeIntervalSince($0.value.date) < 120 }
            received += newlyCreatedRepos.values.map(\.repo).filter { $0.name.hasPrefix(owner + "/") }
            repos = received.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        } catch { if repoRefreshGeneration == generation { self.error = error.localizedDescription } }
    }
    func browse(_ repo: HubRepo, path: String = "", allowMissing: Bool = false) async {
        selectionGeneration = UUID()
        let generation = UUID(); browseGeneration = generation
        currentRepo = repo; remotePath = path; entries = []; browseError = nil; loading = true
        invalidateComparison()
        do {
            var arguments = ["tree", "--repo", repo.name, "--type", repo.kind.rawValue, "--path", path, "--stream"]
            if allowMissing { arguments.append("--allow-missing-path") }
            let result: [RemoteEntry] = try await HubService.request(arguments, token: token)
            guard browseGeneration == generation else { return }
            entries = result.sorted { a, b in a.isDirectory == b.isDirectory ? a.path.localizedStandardCompare(b.path) == .orderedAscending : a.isDirectory }
        } catch { if browseGeneration == generation { browseError = error.localizedDescription } }
        if browseGeneration == generation { loading = false; compareSource() }
    }
    func createRepo(name: String, kind: RepoKind, isPrivate: Bool) async {
        loading = true; defer { loading = false }
        do {
            let response: RepoResponse = try await HubService.request(["create", "--repo", name, "--type", kind.rawValue, "--private", String(isPrivate)], token: token)
            newlyCreatedRepos[response.repo.id] = (response.repo, Date())
            selectedOwner = String(name.split(separator: "/")[0])
            await refreshRepos(); sidebar = response.repo.id; await browse(response.repo); showCreateRepo = false
        } catch { self.error = error.localizedDescription }
    }
    func delete(_ entry: RemoteEntry, from repo: HubRepo) async {
        guard !entry.isDirectory else { return }
        do {
            let _: [String: String] = try await HubService.request(["delete", "--repo", repo.name, "--type", repo.kind.rawValue, "--path", entry.path], token: token)
            if currentRepo == repo { await browse(repo, path: remotePath) }
        } catch { self.error = error.localizedDescription }
    }
    func makeDatasetCardWorkspace() throws -> DatasetCardWorkspace {
        let access = try FolderAccess.restore(path: draftSource, bookmark: draftSourceBookmark)
        return DatasetCardWorkspace(access: access, includes: draftIncludes, excludes: draftExcludes,
                                    destination: remotePath, repository: currentRepo?.name)
    }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK, let url = panel.url { openFolders([url]) }
    }

    func openFolders(_ urls: [URL]) {
        do { receiveFolders(try FolderEntry.capture(urls)) }
        catch { self.error = error.localizedDescription }
    }
    func receiveFolders(_ folders: [FolderEntry]) {
        guard !folders.isEmpty else { return }
        guard datasetCard == nil, uploadReview == nil, pendingFolders.isEmpty, !replacingWorkspace else {
            error = "Finish or cancel the open editor, upload review, or folder selection before opening another folder. No workspace settings were changed."
            return
        }
        if folders.count == 1 { useFolder(folders[0]) }
        else { pendingFolders = folders }
    }
    func useFolder(_ entry: FolderEntry) {
        guard confirmWorkspaceReplacement() else { return }
        pendingFolders = []
        workspaceGeneration = UUID()
        installFolder(entry.access)
    }
    private func confirmWorkspaceReplacement() -> Bool {
        guard datasetCard == nil, uploadReview == nil, !replacingWorkspace else {
            error = "Finish or cancel the open dataset card or upload review before replacing the workspace."
            return false
        }
        guard !draftSource.isEmpty || currentRepo != nil else { return true }
        replacingWorkspace = true
        defer { replacingWorkspace = false }
        let alert = NSAlert()
        alert.messageText = "Replace the prepared workspace?"
        alert.informativeText = "This changes the prepared folder or saved route. Queued and running uploads keep their settings. No upload starts automatically."
        alert.addButton(withTitle: "Keep current"); alert.addButton(withTitle: "Replace workspace")
        return alert.runModal() == .alertSecondButtonReturn
    }

    private func installFolder(_ access: FolderAccess) {
        selectionGeneration = UUID(); browseGeneration = UUID(); loading = false
        workspaceFolderAccess = access
        draftSource = access.url.path; draftSourceBookmark = access.bookmark
        scanSource()
    }
    func scanSource() {
        scanProcess?.stop(); scanGeneration = UUID(); invalidateComparison()
        staging = nil; scanError = nil; scanning = false
        guard !draftSource.isEmpty else { return }
        guard runtimeReady else { scanError = "Set up upload tools to preview this folder."; return }
        let sourceAccess: FolderAccess
        do {
            sourceAccess = try FolderAccess.restore(path: draftSource, bookmark: draftSourceBookmark)
            draftSource = sourceAccess.url.path; draftSourceBookmark = sourceAccess.bookmark
        } catch { scanError = error.localizedDescription; return }
        let generation = scanGeneration
        let process = NativeOperation(); scanProcess = process; scanning = true
        var args = ["scan", "--source", draftSource]
        for pattern in draftIncludes { args += ["--include", pattern] }
        for pattern in draftExcludes { args += ["--exclude", pattern] }
        Task {
            // Keep this operation's own scope until its process actually ends,
            // even if a newer scan or selected folder replaces the workspace.
            defer { sourceAccess.close() }
            do {
                let result: StagingResult = try await HubService.request(args, token: nil, process: process)
                guard generation == scanGeneration else { return }
                staging = result
                compareSource()
            } catch {
                guard generation == scanGeneration else { return }
                scanError = error.localizedDescription
            }
            if generation == scanGeneration { scanning = false; scanProcess = nil }
        }
    }
    private func invalidateComparison() {
        comparisonProcess?.stop(); comparisonProcess = nil
        comparisonGeneration = UUID(); comparison = nil; comparisonError = nil; comparing = false
    }
    func compareSource() {
        invalidateComparison()
        guard let staging, let repo = currentRepo else { return }
        let generation = comparisonGeneration, destination = remotePath
        let process = NativeOperation()
        comparisonProcess = process; comparing = true
        Task {
            let manifest = FileManager.default.temporaryDirectory.appendingPathComponent("face-hugger-compare-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: manifest) }
            do {
                try JSONEncoder().encode(staging.files.filter(\.included).map(\.path)).write(to: manifest, options: .atomic)
                let result: RemoteComparison = try await HubService.request(["compare", "--repo", repo.name, "--type", repo.kind.rawValue, "--destination", destination, "--manifest", manifest.path], token: token, process: process)
                guard comparisonGeneration == generation else { return }
                comparison = result
            } catch {
                guard comparisonGeneration == generation else { return }
                comparisonError = error.localizedDescription
            }
            if comparisonGeneration == generation { comparing = false; comparisonProcess = nil }
        }
    }
    func fileStatus(_ file: StagedFile) -> String {
        if !file.included { return "Excluded" }
        if comparing { return "Checking…" }
        if comparison?.conflicts.contains(where: { Data($0.path.utf8) == Data(file.path.utf8) }) == true { return "Path conflict" }
        guard let comparison else { return "Not checked" }
        if comparison.paths.contains(where: { Data($0.utf8) == Data(file.path.utf8) }) { return "Remote path exists" }
        return comparison.complete ? "New path" : "Not checked"
    }
    func locateSource(for id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .running else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.allowsMultipleSelection = false; panel.prompt = "Use folder"
        panel.message = "Choose the source for this upload. Review its current files before resuming."
        guard panel.runModal() == .OK, let url = panel.url,
              let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .running else { return }
        let access: FolderAccess
        do { access = try FolderAccess.selected(url) }
        catch { self.error = "Could not retain access to this folder. \(error.localizedDescription)"; return }
        workspaceFolderAccess = access
        progress.removeValue(forKey: id)
        jobs[index].source = access.url.path; jobs[index].sourceBookmark = access.bookmark; jobs[index].state = .stopped
        jobs[index].planID = nil
        jobs[index].message = "Source folder updated. Review files, then resume when ready."
        persist()
        draftSource = access.url.path; draftSourceBookmark = access.bookmark
        draftIncludes = jobs[index].includes; draftExcludes = jobs[index].excludes
        scanSource()
        let job = jobs[index]
        Task { await selectRepo(job.repo, path: job.destination) }
    }
    func selectRepo(_ repo: HubRepo, path: String = "") async {
        // Stored visibility can change remotely. Refresh it whenever a destination is selected.
        let generation = UUID(); selectionGeneration = generation; browseGeneration = UUID()
        currentRepo = nil; remotePath = ""; entries = []; loading = true; invalidateComparison()
        defer { if selectionGeneration == generation { loading = false } }
        do {
            let result: RepoResponse = try await HubService.request(["info", "--repo", repo.name, "--type", repo.kind.rawValue], token: token)
            guard selectionGeneration == generation else { return }
            await browse(result.repo, path: path, allowMissing: true)
        } catch { if selectionGeneration == generation { self.error = error.localizedDescription } }
    }
    func applyPairing(_ pairing: SavedPairing) async {
        guard confirmWorkspaceReplacement() else { return }
        let generation = UUID(); workspaceGeneration = generation
        let access: FolderAccess
        do { access = try FolderAccess.restore(path: pairing.source, bookmark: pairing.sourceBookmark) }
        catch { self.error = error.localizedDescription; return }
        workspaceFolderAccess = access
        draftSource = access.url.path; draftSourceBookmark = access.bookmark
        draftIncludes = pairing.includes; draftExcludes = pairing.excludes
        if let index = pairings.firstIndex(where: { $0.id == pairing.id }),
           pairings[index].source != draftSource || pairings[index].sourceBookmark != access.bookmark {
            var updated = pairings
            updated[index].source = draftSource; updated[index].sourceBookmark = access.bookmark
            do { try pairingArchive.save(updated); pairings = updated }
            catch { self.error = "Could not save refreshed folder access: \(error.localizedDescription)" }
        }
        scanSource()
        await selectRepo(pairing.repo, path: pairing.destination)
        guard workspaceGeneration == generation, let folder = try? PairingFolderIdentity(url: access.url) else { return }
        let active = ActivePairing(pairing: pairing, folder: folder)
        if pairingMatches(active) { activePairing = active }
    }
    func savePairing(name: String) {
        guard let repo = currentRepo, !draftSource.isEmpty else { return }
        let pairing = SavedPairing(name: name.trimmingCharacters(in: .whitespacesAndNewlines), source: draftSource, repo: repo, destination: remotePath, includes: draftIncludes, excludes: draftExcludes, sourceBookmark: draftSourceBookmark)
        guard !pairing.name.isEmpty else { return }
        var updated = pairings; updated.append(pairing)
        do {
            try pairingArchive.save(updated); pairings = updated
            if let folder = try? PairingFolderIdentity(url: URL(fileURLWithPath: draftSource)) {
                activePairing = ActivePairing(pairing: pairing, folder: folder)
            }
        } catch { self.error = error.localizedDescription }
    }
    func renamePairing(_ id: UUID, name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        updatePairing(id) { $0.name = name }
    }
    func togglePairingPin(_ id: UUID) { updatePairing(id) { $0.isPinned.toggle() } }
    private func updatePairing(_ id: UUID, change: (inout SavedPairing) -> Void) {
        guard let index = pairings.firstIndex(where: { $0.id == id }) else { return }
        var updated = pairings; change(&updated[index])
        do { try pairingArchive.save(updated); pairings = updated } catch { self.error = error.localizedDescription }
    }
    func movePairing(_ id: UUID, by delta: Int) {
        var ordered = SavedPairing.ordered(pairings)
        guard let index = ordered.firstIndex(where: { $0.id == id }), ordered.indices.contains(index + delta),
              ordered[index].isPinned == ordered[index + delta].isPinned else { return }
        ordered.swapAt(index, index + delta)
        for index in ordered.indices { ordered[index].sortOrder = index }
        do { try pairingArchive.save(ordered); pairings = ordered } catch { self.error = error.localizedDescription }
    }
    func removePairing(_ id: UUID) {
        let updated = pairings.filter { $0.id != id }
        do { try pairingArchive.save(updated); pairings = updated } catch { self.error = error.localizedDescription }
    }
    func submitStaged(start: Bool) async {
        guard !submitting, !scanning, let staging, staging.includedCount > 0, let repo = currentRepo else { return }
        let job = UploadJob(source: draftSource, repo: repo, destination: remotePath, includes: draftIncludes,
                            excludes: draftExcludes, fileCount: staging.includedCount, byteCount: staging.includedBytes,
                            sourceBookmark: draftSourceBookmark)
        beginUploadReview(job: job, start: start, replacesJob: false)
    }
    func reviewUpload(_ id: UUID) {
        guard let job = jobs.first(where: { $0.id == id }), job.state != .running else { return }
        beginUploadReview(job: job, start: true, replacesJob: true)
    }
    private func beginUploadReview(job: UploadJob, start: Bool, replacesJob: Bool) {
        guard uploadReview == nil else { return }
        let workspace = UploadReviewWorkspace(job: job, directory: AppPaths.uploadPlans, start: start, replacesJob: replacesJob)
        uploadReview = workspace
        let credential = token
        Task { await workspace.prepare(token: credential) }
    }
    func cancelUploadReview() { uploadReview?.cancel(); uploadReview = nil }
    func approveUploadReview() {
        guard let workspace = uploadReview else { return }
        do {
            let job = try workspace.approve()
            var updated = jobs
            if workspace.replacesJob {
                guard let index = updated.firstIndex(where: { $0.id == job.id }), updated[index].state != .running else {
                    throw NativeUploadError.reviewRequired("The queue item changed while its review was open. Close this review and try again.")
                }
                updated[index] = job
            } else { updated.append(job) }
            // Publish the queue reference only after its approved plan and archive are saved.
            try archive.save(updated)
            jobs = updated; selectedJobID = job.id; sidebar = "uploads"
            workspace.keepPlan(); uploadReview = nil
            if workspace.startWhenApproved { queueControl.start(preferredJobID: job.id); runNext() }
        } catch { workspace.error = error.localizedDescription }
    }

    func addJob(_ job: UploadJob, start: Bool) {
        jobs.append(job); selectedJobID = job.id; sidebar = "uploads"; persist()
        if start { queueControl.start(preferredJobID: job.id); runNext() }
    }
    func resume(_ id: UUID) {
        guard let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state != .running else { return }
        let receipt = transferReceipts.first { $0.jobID == id && $0.outcome != .running }
        if jobs[index].planID == nil || ["review-required", "source-changed"].contains(receipt?.failure?.category ?? "") {
            reviewUpload(id); return
        }
        jobs[index].state = .queued; jobs[index].message = "Ready to resume"; jobs[index].finishedAt = nil
        queueControl.start(preferredJobID: id); persist(); runNext()
    }
    func startQueue() { queueControl.start(); runNext() }
    func stop() { queueControl.stop(); runner?.stop() }
    func remove(_ id: UUID) {
        guard jobs.first(where: { $0.id == id })?.state != .running else { return }
        do {
            if FileManager.default.fileExists(atPath: AppPaths.checkpoints.path) {
                for folder in try FileManager.default.contentsOfDirectory(at: AppPaths.checkpoints, includingPropertiesForKeys: nil)
                    where folder.lastPathComponent.hasPrefix(id.uuidString + "-") {
                    try FileManager.default.removeItem(at: folder)
                }
            }
            if FileManager.default.fileExists(atPath: AppPaths.uploadPlans.path) {
                for file in try FileManager.default.contentsOfDirectory(at: AppPaths.uploadPlans, includingPropertiesForKeys: nil) {
                    let pattern = "^" + id.uuidString + "-[A-Fa-f0-9-]{36}\\.sqlite(-journal|-wal|-shm)?$"
                    if file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil { try FileManager.default.removeItem(at: file) }
                }
            }
        } catch { self.error = "Could not remove this upload’s local checkpoints: \(error.localizedDescription)"; return }
        jobs.removeAll { $0.id == id }; logs.removeValue(forKey: id); progress.removeValue(forKey: id)
        transferActivity.removeValue(forKey: id); persist()
    }
    func move(from: IndexSet, to: Int) { jobs.move(fromOffsets: from, toOffset: to); persist() }
    func clearTransferHistory() {
        do {
            try transferHistory?.clearTerminalReceipts()
            transferReceipts = transferHistory?.receipts ?? []
        } catch { self.error = "Could not clear transfer history: \(error.localizedDescription)" }
    }
    func runNext() {
        guard runner == nil else { return }
        guard runtimeReady else { showSettings = true; return }
        guard let transferHistory else { error = "Transfer history is unavailable. Restart after resolving its read or write error."; return }
        guard let nextID = queueControl.beginNext(in: jobs), let index = jobs.firstIndex(where: { $0.id == nextID }) else { return }
        guard jobs[index].planID != nil else {
            jobs[index].state = queueControl.finish(nextID, exitStatus: -1) ?? .failed
            jobs[index].message = "Review this saved upload before starting it with version 1.1."
            persist(); reviewUpload(nextID); return
        }
        let recorder: TransferAttemptRecorder
        do { recorder = try transferHistory.begin(job: jobs[index]) }
        catch {
            jobs[index].state = queueControl.finish(nextID, exitStatus: -1) ?? .failed
            jobs[index].message = "Could not save an attempt record. No upload was started."
            self.error = "Could not save transfer history: \(error.localizedDescription)"; persist(); return
        }
        activeAttemptID = recorder.snapshot.receipt.id; receivedSequence = 0
        jobs[index].state = .running; jobs[index].message = "Starting upload…"; persist()
        transferReceipts = transferHistory.receipts
        progress.removeValue(forKey: nextID); logs[nextID] = ""
        transferActivity.removeValue(forKey: nextID)
        let sourceAccess: FolderAccess
        do {
            sourceAccess = try FolderAccess.restore(path: jobs[index].source, bookmark: jobs[index].sourceBookmark)
            jobs[index].source = sourceAccess.url.path; jobs[index].sourceBookmark = sourceAccess.bookmark
        } catch {
            jobs[index].message = error.localizedDescription
            finish(nextID, status: -1, recorder: recorder, failure: error); return
        }
        let job = jobs[index]
        if let problem = UploadValidation.error(source: job.source, repo: job.repo.name, destination: job.destination) {
            sourceAccess.close()
            jobs[index].message = problem
            finish(job.id, status: -1, recorder: recorder, failure: NativeUploadError.invalid(problem)); return
        }
        if keepAwake { activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "Uploading files to Hugging Face") }
        let command = NativeOperation(); runner = command
        let observer = Task { @MainActor in
            while !Task.isCancelled {
                receive(recorder.snapshot)
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
        }
        Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        Task {
            defer { sourceAccess.close() }
            var status: Int32 = -1
            var failure: (any Error)?
            do {
                let credential = token
                try await command.run {
                    try await ReviewedUploader.upload(job: job, plansDirectory: AppPaths.uploadPlans, token: credential) { event in
                        do { try recorder.record(event) }
                        catch { command.stop() }
                    }
                }
                status = 0
            } catch is CancellationError { status = 143 }
            catch { failure = error }
            observer.cancel()
            receive(recorder.snapshot)
            if recorder.persistenceFailed {
                status = -1; failure = CocoaError(.fileWriteUnknown)
                self.error = "An upload was stopped because its confirmed results could not be saved. Check local storage before resuming."
            }
            finish(job.id, status: status, recorder: recorder, failure: failure)
        }
    }
    private func receive(_ snapshot: TransferAttempt) {
        let id = snapshot.receipt.jobID
        guard snapshot.receipt.id == activeAttemptID,
              let index = jobs.firstIndex(where: { $0.id == id }), jobs[index].state == .running else { return }
        if transferActivity[id] != snapshot.activity { transferActivity[id] = snapshot.activity }
        guard snapshot.sequence > receivedSequence else { return }
        receivedSequence = snapshot.sequence
        jobs[index].message = snapshot.status
        if let value = snapshot.receipt.progress {
            progress[id] = UploadProgress(native: value); jobs[index].fileCount = value.total
        }
        logs[id] = snapshot.log.joined(separator: "\n")
    }
    private func finish(_ id: UUID, status: Int32, recorder: TransferAttemptRecorder, failure: (any Error)? = nil) {
        guard let state = queueControl.finish(id, exitStatus: status) else { return }
        do {
            let outcome: TransferOutcome = state == .completed ? .completed : state == .stopped ? .stopped : .failed
            try recorder.finish(outcome, error: failure)
        } catch {
            queueControl.stop()
            self.error = "The transfer ended, but its receipt could not be saved: \(error.localizedDescription)"
        }
        let snapshot = recorder.snapshot
        transferActivity[id] = snapshot.activity
        transferReceipts = transferHistory?.receipts ?? []
        logs[id] = snapshot.log.joined(separator: "\n")
        activeAttemptID = nil
        if let activity { ProcessInfo.processInfo.endActivity(activity); self.activity = nil }
        runner = nil
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        jobs[index].state = state
        switch state {
        case .stopped: jobs[index].message = "Stopped. Already committed files remain in the repo."
        case .completed:
            let value = snapshot.receipt.progress
            if (value?.total ?? 0) > 0 && value?.identicalFiles == value?.total {
                jobs[index].message = "Verified: no changes needed."
            } else if (value?.total ?? 0) > 0 && value?.ignoredFiles == value?.total {
                jobs[index].message = "No changes: the repository ignored all selected files."
            } else { jobs[index].message = "Upload complete" }
            jobs[index].finishedAt = Date()
        case .failed: jobs[index].message = snapshot.receipt.failure?.message ?? "Upload failed. Inspect the log and resume when ready."
        default: break
        }
        persist()
        if state == .completed, currentRepo?.id == jobs[index].repo.id {
            let repo = jobs[index].repo, path = remotePath
            Task { await browse(repo, path: path) }
        }
        let content = UNMutableNotificationContent(); content.title = state == .completed ? "Upload complete" : state == .failed ? "Upload needs attention" : "Upload stopped"; content.body = jobs[index].title
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
        runNext()
    }
}
