import Foundation

/// Retains a user-granted scope while an open event waits for a window or selection.
public struct FolderEntry: Identifiable {
    public let id = UUID()
    public let access: FolderAccess
    public var url: URL { access.url }

    public static func capture(_ urls: [URL]) throws -> [FolderEntry] {
        var entries: [FolderEntry] = []
        var identities: [PairingFolderIdentity] = []
        for url in urls {
            guard url.isFileURL else { throw EntryError.foldersOnly }
            let access = try captureAccess(url)
            let values = try access.url.resolvingSymlinksInPath().resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true else { throw EntryError.foldersOnly }
            let identity = try PairingFolderIdentity(url: access.url)
            if identities.contains(identity) { continue }
            identities.append(identity); entries.append(FolderEntry(access: access))
        }
        return entries
    }

    private static func captureAccess(_ url: URL) throws -> FolderAccess {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved != url.standardizedFileURL else { return try FolderAccess.selected(url) }
        // A symlink URL may not itself support bookmark creation. Keep its grant
        // alive while creating and independently acquiring the target bookmark.
        let started = url.startAccessingSecurityScopedResource()
        defer { if started { url.stopAccessingSecurityScopedResource() } }
        let selected = try FolderAccess.selected(resolved)
        defer { selected.close() }
        return try FolderAccess.restore(path: resolved.path, bookmark: selected.bookmark)
    }

    public enum EntryError: LocalizedError {
        case foldersOnly
        public var errorDescription: String? {
            "Open local folders to prepare an upload. Files and application packages are not supported. No folders from this selection were opened."
        }
    }
}
