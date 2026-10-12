import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainView: View {
    @Bindable var model: AppModel
    @State private var showRepos = false
    @State private var showPairings = false
    @State private var showFilters = false
    @State private var showDestination = false
    @State private var dropTarget = false
    @State private var savePairing = false
    @State private var pairingName = ""
    @State private var pendingPairing: SavedPairing?
    @State private var pendingSource: URL?
    @State private var localSearch = ""
    @State private var sourceSelection: Data?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                localPane.frame(maxWidth: .infinity)
                Rectangle().fill(BenchTheme.divider).frame(width: 1)
                remotePane.frame(maxWidth: .infinity)
            }
            .overlay(alignment: .top) {
                Image(systemName: "arrow.right").font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(red: 0.15, green: 0.2, blue: 0.26))
                    .frame(width: 32, height: 32).background(BenchTheme.gold, in: Circle())
                    .padding(.top, 56).allowsHitTesting(false).accessibilityHidden(true)
            }
            comparisonBar
            reviewBar
            TransferShelf(model: model)
        }
        .foregroundStyle(BenchTheme.ink)
        .frame(minWidth: 1040, minHeight: 680)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Image("Hugger").resizable().scaledToFit().frame(width: 28, height: 28).accessibilityHidden(true)
                    Text("Face Hugger").font(.system(size: 14, weight: .semibold))
                }
            }
            .benchTitleBackground()
            ToolbarItemGroup(placement: .primaryAction) {
                Button { showPairings.toggle() } label: { Label("Pairings", systemImage: "link").labelStyle(.titleAndIcon) }
                    .popover(isPresented: $showPairings, arrowEdge: .bottom) { pairingPicker }
                Button { model.showSettings = true } label: { Label(model.identity?.name ?? "Connect", systemImage: "person.crop.circle").labelStyle(.titleAndIcon) }
                    .help("Account and settings")
            }
        }
        .sheet(isPresented: $model.showSettings) { SettingsSheet(model: model) }
        .sheet(isPresented: $model.showCreateRepo) { CreateRepoSheet(model: model) }
        .sheet(item: $model.datasetCard) { workspace in
            DatasetCardSheet(workspace: workspace, onSaved: { model.scanSource() })
        }
        .sheet(isPresented: $showDestination) { DestinationSheet(model: model) }
        .alert("Face Hugger", isPresented: Binding(get: { model.error != nil && !model.showSettings && !model.showCreateRepo }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .alert("Save pairing", isPresented: $savePairing) {
            TextField("Name", text: $pairingName)
            Button("Cancel", role: .cancel) { }
            Button("Save") { model.savePairing(name: pairingName) }
        } message: { Text("Remember this folder, repository, destination path, and filters. Uploads always start manually.") }
        .confirmationDialog("Replace the prepared folder and destination?", isPresented: Binding(get: { pendingPairing != nil }, set: { if !$0 { pendingPairing = nil } })) {
            Button("Use pairing") { if let pairing = pendingPairing { Task { await model.applyPairing(pairing) } }; pendingPairing = nil }
            Button("Keep current", role: .cancel) { pendingPairing = nil }
        } message: { Text("This replaces the workspace configuration. Existing queued and running uploads keep their original settings.") }
        .confirmationDialog("Replace the prepared folder?", isPresented: Binding(get: { pendingSource != nil }, set: { if !$0 { pendingSource = nil } })) {
            Button("Use folder") { if let url = pendingSource { model.stageFolder(url) }; pendingSource = nil }
            Button("Keep current", role: .cancel) { pendingSource = nil }
        }
        .task { if model.runtimeReady && model.hasExistingCredentials { await model.connect() } }
        .onChange(of: model.runtimeReady) { _, ready in if ready { model.scanSource() } }
    }

    private var localPane: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("On this Mac").font(BenchTheme.metadata.weight(.medium)).foregroundStyle(BenchTheme.secondary)
                    .frame(height: 14).padding(.bottom, 8)
                Text(model.draftSource.isEmpty ? "Choose a local folder" : URL(fileURLWithPath: model.draftSource).lastPathComponent)
                    .font(BenchTheme.title).lineLimit(1).truncationMode(.middle)
                    .frame(height: 30, alignment: .leading).padding(.bottom, 4)
                Text(model.draftSource.isEmpty ? "No folder selected" : model.draftSource.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary).lineLimit(1).truncationMode(.middle)
                    .help(model.draftSource.isEmpty ? "Choose a local folder to prepare files" : model.draftSource)
                    .frame(height: 16, alignment: .leading).padding(.bottom, 10)
                HStack {
                    Button(model.draftSource.isEmpty ? "Choose folder…" : "Choose another folder…", systemImage: "folder") { model.chooseFolder() }
                        .buttonStyle(.plain).font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary)
                    Spacer(minLength: 0)
                }.frame(height: 20)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
            .frame(height: BenchTheme.paneHeaderHeight)
            Rectangle().fill(BenchTheme.divider).frame(height: 1)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(BenchTheme.secondary)
                TextField("Find in preview", text: $localSearch).textFieldStyle(.plain).accessibilityLabel("Filter local preview")
                if !localSearch.isEmpty {
                    Button { localSearch = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(BenchTheme.secondary) }
                        .buttonStyle(.plain).help("Clear filter").accessibilityLabel("Clear local preview filter")
                }
                if model.scanning { ProgressView().controlSize(.small) }
                else if !model.draftSource.isEmpty {
                    Button { model.scanSource() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.plain).foregroundStyle(BenchTheme.secondary).help("Refresh local preview").accessibilityLabel("Refresh local preview")
                }
            }.font(BenchTheme.metadata).padding(.horizontal, 24).frame(height: BenchTheme.utilityHeight)
            Rectangle().fill(BenchTheme.divider).frame(height: 1)
            localFiles
            Rectangle().fill(BenchTheme.divider).frame(height: 1)
            HStack {
                Text(localFootnote).lineLimit(2)
                Spacer(minLength: 0)
            }.font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary).padding(.horizontal, 24).frame(height: BenchTheme.footerHeight)
        }
        .background(BenchTheme.source)
        .overlay { if dropTarget { Rectangle().strokeBorder(BenchTheme.gold, lineWidth: 3).allowsHitTesting(false) } }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, url.isFileURL else { return false }
            if !model.draftSource.isEmpty && model.draftSource != url.path { pendingSource = url } else { model.stageFolder(url) }
            return true
        } isTargeted: { dropTarget = $0 }
    }
    @ViewBuilder private var localFiles: some View {
        if model.draftSource.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.plus").font(.system(size: 46, weight: .light)).foregroundStyle(BenchTheme.secondary)
                Text("Drop a folder here to prepare an upload").font(.system(size: 13)).foregroundStyle(BenchTheme.secondary)
                if !model.runtimeReady { Button("Set up upload tools") { model.showSettings = true }.buttonStyle(.bordered) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.scanError {
            VStack(alignment: .leading, spacing: 12) {
                Label("Couldn’t preview this folder", systemImage: "exclamationmark.circle").font(.headline)
                Text(error).font(.system(size: 13)).textSelection(.enabled)
                Button("Locate folder…") { model.chooseFolder() }
                Button(model.runtimeReady ? "Try again" : "Set up upload tools") { if model.runtimeReady { model.scanSource() } else { model.showSettings = true } }
            }.padding(28).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else if let result = model.staging {
            let filteredFiles = result.files.filter { localSearch.isEmpty || $0.path.localizedCaseInsensitiveContains(localSearch) }
            if !localSearch.isEmpty && filteredFiles.isEmpty {
                ContentUnavailableView {
                    Label("No matching files", systemImage: "magnifyingglass")
                } description: {
                    Text("No files in this preview match “\(localSearch)”.")
                } actions: {
                    Button("Clear search") { localSearch = "" }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(filteredFiles, selection: $sourceSelection) {
                    TableColumn("Name") { file in
                        HStack(spacing: 8) {
                            Image(systemName: file.included ? "checkmark.circle.fill" : "minus.circle").foregroundStyle(file.included ? BenchTheme.secondary : BenchTheme.secondary.opacity(0.7))
                                .accessibilityLabel(file.included ? "Included" : "Excluded")
                            Text(file.path).font(.system(size: 13)).foregroundStyle(file.included ? BenchTheme.ink : BenchTheme.secondary)
                                .strikethrough(!file.included).lineLimit(1).truncationMode(.middle).help(file.path)
                        }.frame(minHeight: 31)
                    }
                    TableColumn("Status") { file in
                        Text(model.fileStatus(file)).font(BenchTheme.metadata)
                            .foregroundStyle(file.included && model.comparison?.paths.contains(file.path) == true ? BenchTheme.pathMatch : BenchTheme.secondary)
                            .help(model.comparison?.conflicts.first(where: { $0.path == file.path })?.reason ?? "Path comparison only. File contents have not been compared.")
                    }.width(125)
                    TableColumn("Size") { file in Text(ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)).font(.system(size: 12)).monospacedDigit().foregroundStyle(BenchTheme.secondary) }.width(80)
                }.tableStyle(.inset(alternatesRowBackgrounds: false)).scrollContentBackground(.hidden)
            }
        } else {
            VStack(spacing: 12) { ProgressView(); Text("Reading files and applying filters…").font(.system(size: 13)).foregroundStyle(BenchTheme.secondary) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
    private var localFootnote: String {
        guard let staging = model.staging else { return "Preview files before uploading" }
        if staging.truncated { return "Showing the first \(staging.files.count) of \(staging.totalCount) files. Totals include all files." }
        return "\(staging.totalCount) files found · \(staging.totalCount - staging.includedCount) excluded"
    }
    @ViewBuilder private var remotePane: some View {
        Group {
            if let repo = model.currentRepo {
                RepoBrowser(model: model, repo: repo, chooseRepository: { showRepos = true }, draftDatasetCard: {
                    do { model.datasetCard = try model.makeDatasetCardWorkspace() }
                    catch { model.error = error.localizedDescription }
                })
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("On Hugging Face").font(BenchTheme.metadata.weight(.medium)).foregroundStyle(BenchTheme.secondary)
                            .frame(height: 14).padding(.bottom, 8)
                        Text("Choose a repository").font(BenchTheme.title).lineLimit(1).truncationMode(.middle)
                            .frame(height: 30, alignment: .leading).padding(.bottom, 4)
                        Text(model.identity == nil ? "Connect your Hugging Face account" : "No repository selected")
                            .font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary).lineLimit(1)
                            .frame(height: 16, alignment: .leading).padding(.bottom, 10)
                        HStack {
                            Button(model.identity == nil ? "Connect account…" : "Browse repositories…", systemImage: model.identity == nil ? "person.crop.circle" : "folder") {
                                if model.identity == nil { model.showSettings = true } else { showRepos = true }
                            }.buttonStyle(.plain).font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary)
                            Spacer(minLength: 0)
                        }.frame(height: 20)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24).padding(.top, 18).padding(.bottom, 16)
                    .frame(height: BenchTheme.paneHeaderHeight)
                    Rectangle().fill(BenchTheme.divider).frame(height: 1)
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass")
                        Text("Choose a repository to browse files")
                        Spacer(minLength: 0)
                    }.font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary)
                        .padding(.horizontal, 24).frame(height: BenchTheme.utilityHeight)
                    Rectangle().fill(BenchTheme.divider).frame(height: 1)
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Give this folder a destination.").font(.system(size: 15, weight: .medium))
                        Text("Browse a model or dataset repository, then choose where the files should go.").font(.system(size: 13)).foregroundStyle(BenchTheme.secondary)
                        if model.identity != nil { Button("Create repository…", systemImage: "plus") { model.showCreateRepo = true } }
                    }.padding(24)
                    Spacer()
                    Rectangle().fill(BenchTheme.divider).frame(height: 1)
                    Text("Choose where your files will arrive")
                        .font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary)
                        .padding(.horizontal, 24).frame(height: BenchTheme.footerHeight)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).background(BenchTheme.remote)
            }
        }.popover(isPresented: $showRepos, arrowEdge: .top) { RepositoryPicker(model: model) { showRepos = false } }
    }
    @ViewBuilder private var comparisonBar: some View {
        if model.staging != nil && model.currentRepo != nil {
            HStack(spacing: 10) {
                if model.comparing { ProgressView().controlSize(.small) }
                Text(model.comparison?.conflicts.isEmpty == false ? "File/folder conflicts found. Choose another destination or resolve the remote paths before uploading." : model.comparing ? "Checking remote paths…" : model.comparisonError != nil ? "Remote paths couldn’t be checked." : model.comparison?.complete == false ? "Remote check reached its limit. Some paths remain unchecked." : "Path check covers previewed files only. Contents have not been compared.")
                    .font(BenchTheme.metadata).foregroundStyle(BenchTheme.secondary)
                Spacer()
                if model.comparisonError != nil {
                    Button("Account…") { model.showSettings = true }
                }
                Button("Check again") { model.compareSource() }.disabled(model.comparing)
                    .help(model.comparisonError ?? "Refresh remote path status")
            }.padding(.horizontal, 24).padding(.vertical, 8).background(BenchTheme.source)
        }
    }
    private var reviewBar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(summary).font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    Text(model.currentRepo == nil ? "Choose a repository to continue" : "Matching remote paths may be replaced; other files stay in place.")
                        .font(.system(size: 12)).foregroundStyle(BenchTheme.secondary)
                }
                Button("Filters", systemImage: "line.3.horizontal.decrease") { showFilters.toggle() }
                    .popover(isPresented: $showFilters) { FilterEditor(model: model) { showFilters = false } }
                if model.currentRepo != nil {
                    Button(model.remotePath.isEmpty ? "To root…" : "To /\(model.remotePath)", systemImage: "folder") { showDestination = true }
                        .lineLimit(1).frame(maxWidth: 160).help("Choose a folder within the repository")
                }
                Spacer(minLength: 8)
                if model.submitting { ProgressView().controlSize(.small) }
                Menu {
                    Button("Add to queue") { Task { await model.submitStaged(start: false) } }
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 20).disabled(!canUpload).accessibilityLabel("More upload actions")
                Button(model.activeJob == nil ? "Upload \(model.staging?.includedCount ?? 0) files" : "Queue upload") {
                    Task { await model.submitStaged(start: model.activeJob == nil) }
                }.buttonStyle(BenchUploadButton()).disabled(!canUpload).keyboardShortcut(.return, modifiers: .command)
            }.padding(.horizontal, 24).frame(height: 76)
        }.background(BenchTheme.remote)
    }
    private var canUpload: Bool { model.runtimeReady && !model.scanning && !model.submitting && model.comparison?.conflicts.isEmpty != false && model.currentRepo != nil && (model.staging?.includedCount ?? 0) > 0 }
    private var summary: String {
        if model.scanning { return "Preparing folder…" }
        guard let result = model.staging else { return "No files prepared" }
        return "\(result.includedCount) files / \(ByteCountFormatter.string(fromByteCount: result.includedBytes, countStyle: .file))"
    }
    private var pairingPicker: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved pairings").font(.system(size: 15, weight: .semibold))
            if model.pairings.isEmpty {
                Text("Save a folder and its destination for the next upload.").font(.system(size: 13)).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(model.pairings) { pairing in
                            HStack {
                                Button {
                                    showPairings = false
                                    if !model.draftSource.isEmpty { pendingPairing = pairing } else { Task { await model.applyPairing(pairing) } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(pairing.name).font(.system(size: 13, weight: .medium))
                                        Text(URL(fileURLWithPath: pairing.source).lastPathComponent + " → " + pairing.repo.name + (pairing.destination.isEmpty ? "" : "/" + pairing.destination))
                                            .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(6).contentShape(Rectangle())
                                }.buttonStyle(.plain)
                                Button { model.removePairing(pairing.id) } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).help("Remove saved pairing").accessibilityLabel("Remove saved pairing \(pairing.name)")
                            }
                        }
                    }
                }.frame(maxHeight: 250)
            }
            Divider()
            Button("Save current pairing…", systemImage: "plus") { pairingName = URL(fileURLWithPath: model.draftSource).lastPathComponent; showPairings = false; savePairing = true }
                .disabled(model.draftSource.isEmpty || model.currentRepo == nil)
            Text("Pairings never start an upload automatically.").font(.system(size: 12)).foregroundStyle(.secondary)
        }.padding(18).frame(width: 360)
    }
}

struct BenchUploadButton: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).padding(.horizontal, 20).padding(.vertical, 10)
            .foregroundStyle(enabled ? Color(red: 0.15, green: 0.2, blue: 0.26) : BenchTheme.secondary)
            .background(enabled ? BenchTheme.gold.opacity(configuration.isPressed ? 0.75 : 1) : BenchTheme.divider.opacity(0.4), in: RoundedRectangle(cornerRadius: 7))
    }
}

private extension ToolbarContent {
    @ToolbarContentBuilder
    func benchTitleBackground() -> some ToolbarContent {
        self.sharedBackgroundVisibility(.hidden)
    }
}
