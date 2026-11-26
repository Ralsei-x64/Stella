import Darwin
import Foundation

struct AdditionalDrive: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case image, folder, volume, raw
    }

    let id: UUID
    let kind: Kind
    let name: String
    var enabled = true
    var readOnly = false
    var sizeGiB: Int?
    var bookmark: Data?
    var volumeUUID: String?
    var physicalID: String?

    static var skipped: [UUID: String] = [:]
    static let maxCount = 12
    static let capacities = 1...8192
    static let directory = URL(fileURLWithPath: AppBundle.appSupportDir).appendingPathComponent("Drives")
    var uuid: String { id.uuidString.lowercased() }
    var token: String { String(uuid.replacingOccurrences(of: "-", with: "").prefix(16)) }
    var tag: String { "st-" + token }
    var mountName: String {
        let ascii = name.folding(options: [.diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        let parts = ascii.utf8.map { byte -> Character in
            switch byte {
            case 48...57, 65...90, 97...122: return Character(UnicodeScalar(byte))
            default: return "-"
            }
        }
        let slug = String(String(parts).split(separator: "-").joined(separator: "-").prefix(24))
        return (slug.isEmpty ? "Drive" : slug) + "-" + token.prefix(6)
    }
    var mountPath: String { "/run/media/stella/" + mountName }
    func imageURL(in directory: URL = Self.directory) -> URL {
        directory.appendingPathComponent(uuid + ".img")
    }
    func createImage(in directory: URL = Self.directory) throws {
        guard kind == .image, let sizeGiB, Self.capacities.contains(sizeGiB) else {
            throw OptionError(String(localized: "Choose a capacity from 1 to 8192 GiB."))
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let path = imageURL(in: directory).path
        let fd = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        let marker = Array(("STELLA-EMPTY-1 " + uuid + "\n").utf8)
        guard ftruncate(fd, Int64(sizeGiB) << 30) == 0,
              marker.withUnsafeBytes({ write(fd, $0.baseAddress, $0.count) }) == marker.count,
              fsync(fd) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            unlink(path) // exclusively created by this call
            throw error
        }
    }

    @discardableResult
    func trashImage(in directory: URL = Self.directory) throws -> URL? {
        guard kind == .image else { throw OptionError(String(localized: "Only virtual disks created by Stella can be deleted.")) }
        let url = imageURL(in: directory)
        var entry = stat()
        guard lstat(url.path, &entry) == 0, entry.st_mode & S_IFMT == S_IFREG else {
            throw OptionError(String(localized: "The virtual disk image is missing or was replaced."))
        }
        let fd = try DiskLock.lock(url.path)
        defer { close(fd) }
        var trashed: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &trashed)
        return trashed as URL?
    }

    func resolveFolder() throws -> URL {
        guard let bookmark else { throw OptionError(String(localized: "Select the folder or volume again.")) }
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting],
                          relativeTo: nil, bookmarkDataIsStale: &stale)
        if let volumeUUID, try url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString != volumeUUID {
            throw OptionError(String(localized: "The original volume is disconnected."))
        }
        guard Options.isReadableFolder(url.path), readOnly || FileManager.default.isWritableFile(atPath: url.path),
              kind != .volume || Self.isShareableVolume(url) else { throw OptionError(String(localized: "The selected volume or folder is unavailable.")) }
        return url
    }

    static func isShareableVolume(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.path != "/", let values = try? resolved.resourceValues(forKeys: [.isVolumeKey, .volumeIsInternalKey]),
              values.isVolume == true else { return false }
        // Some removable file systems leave volumeIsInternal unset. Finder's visible volume roots
        // under /Volumes still distinguish those from arbitrary folders and macOS system mounts.
        if let internalVolume = values.volumeIsInternal { return !internalVolume }
        let mounted = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? []
        return resolved.deletingLastPathComponent().path == "/Volumes" &&
            mounted.contains { $0.resolvingSymlinksInPath().standardizedFileURL.path == resolved.path }
    }

    static func attach(_ drives: [Self], to options: inout Options, directory: URL = Self.directory) {
        guard !options.needsDisk, !options.disks.isEmpty, !options.explicit.contains("--disk") else { return }
        var records = [String]()
        var seen = Set<String>()
        for drive in drives.prefix(maxCount) where drive.enabled && seen.insert(drive.token).inserted {
            do {
                switch drive.kind {
                case .image:
                    let path = drive.imageURL(in: directory).path
                    var st = stat()
                    guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG,
                          FileManager.default.isWritableFile(atPath: path) else { throw OptionError(String(localized: "Image unavailable")) }
                    options.disks.append(DiskSpec(path: path, readOnly: false, serial: drive.tag))
                    records.append("i:\(drive.uuid):\(drive.mountName)")
                case .volume, .folder:
                    let url = try drive.resolveFolder()
                    options.driveShares.append((drive.tag, url.path, drive.readOnly))
                    let mode = drive.readOnly ? "r" : "f"
                    records.append("\(mode):\(drive.uuid):\(drive.mountName)")
                case .raw:
                    options.physicalDrives.append(drive)
                }
            } catch {
                skipped[drive.id] = error.localizedDescription
                log("drive \(drive.name): \(error.localizedDescription); skipping this boot")
            }
        }
        if !records.isEmpty { options.cmdline += " stella.drives=" + records.joined(separator: ",") }
        if !options.physicalDrives.isEmpty { options.cmdline += " stella.raw=1" }
    }
}
