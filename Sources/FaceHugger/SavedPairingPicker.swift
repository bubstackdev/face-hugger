import SwiftUI

struct SavedPairingPicker: View {
    let pairings: [SavedPairing]
    let activeID: UUID?
    let canSave: Bool
    let onUse: (SavedPairing) -> Void
    let onRename: (UUID, String) -> Void
    let onPin: (UUID) -> Void
    let onMove: (UUID, Int) -> Void
    let onRemove: (UUID) -> Void
    let onSave: () -> Void
    @State private var search = ""
    @State private var renaming: SavedPairing?
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Saved pairings").font(.headline)
            TextField("Search name, folder, repository, or destination", text: $search)
                .textFieldStyle(.roundedBorder).accessibilityLabel("Search saved pairings")
            let ordered = SavedPairing.ordered(pairings)
            let visible = ordered.filter { $0.matches(search: search) }
            if visible.isEmpty {
                Text(pairings.isEmpty ? "Save a folder and its destination for the next upload." : "No matching pairings.")
                    .font(.callout).foregroundStyle(.secondary).padding(.vertical, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(visible) { pairing in
                            HStack(spacing: 10) {
                                Button { onUse(pairing) } label: {
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack(spacing: 6) {
                                            if pairing.isPinned { Image(systemName: "pin.fill").accessibilityLabel("Pinned") }
                                            Text(pairing.name).fontWeight(.medium).lineLimit(2)
                                            if activeID == pairing.id {
                                                Label("Active", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                                            }
                                        }
                                        Text(URL(fileURLWithPath: pairing.source).lastPathComponent + " → " + pairing.repo.name + (pairing.destination.isEmpty ? " /" : " /" + pairing.destination))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 5).contentShape(Rectangle())
                                }.buttonStyle(.plain).help("Prepare this saved route; no upload starts")
                                Menu {
                                    Button("Rename…") { name = pairing.name; renaming = pairing }
                                    Button(pairing.isPinned ? "Unpin" : "Pin") { onPin(pairing.id) }
                                    let index = ordered.firstIndex(where: { $0.id == pairing.id }) ?? 0
                                    Button("Move up") { onMove(pairing.id, -1) }
                                        .disabled(index == 0 || ordered[index - 1].isPinned != pairing.isPinned)
                                    Button("Move down") { onMove(pairing.id, 1) }
                                        .disabled(index + 1 >= ordered.count || ordered[index + 1].isPinned != pairing.isPinned)
                                    Divider()
                                    Button("Remove pairing", role: .destructive) { onRemove(pairing.id) }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Options for \(pairing.name)")
                            }
                        }
                    }
                }.frame(maxHeight: 300)
            }
            Divider()
            Button("Save current pairing…", systemImage: "plus", action: onSave).disabled(!canSave)
            Text("Pairings never start an upload automatically.").font(.caption).foregroundStyle(.secondary)
        }.padding(18).frame(width: 430)
        .alert("Rename pairing", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $name)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Save") {
                if let pairing = renaming { onRename(pairing.id, name) }
                renaming = nil
            }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: { Text("The saved folder, destination, and filters stay the same.") }
    }
}

struct FolderSelectionView: View {
    let folders: [FolderEntry]
    let onChoose: (FolderEntry) -> Void
    let onCancel: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose a folder to prepare").font(.title2.weight(.semibold))
            Text("Open one folder at a time. The other folders will remain unopened. No upload starts automatically.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(folders) { folder in
                        Button { onChoose(folder) } label: {
                            HStack {
                                Image(systemName: "folder")
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(folder.url.lastPathComponent).fontWeight(.medium)
                                    Text(folder.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                            }.padding(8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
        }.padding(24).frame(width: 560, height: 400).interactiveDismissDisabled()
    }
}
