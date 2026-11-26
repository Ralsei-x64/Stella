import CKrun
import Darwin
import Foundation
import IOKit

/// Never persist a BSD device number. Disk numbers are recycled when USB media disconnects.
struct PhysicalDisk: Identifiable {
    let id: String
    let device: String
    let name: String
    let bytes: Int64
    let registryID: UInt64
    let writable: Bool

    private static func info(_ arguments: [String]) throws -> [String: Any] {
        let process = Process(), pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let dict = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw OptionError(String(localized: "macOS could not read the disk inventory."))
        }
        return dict
    }

    private static func registryID(_ bsd: String) -> UInt64? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        return IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS ? id : nil
    }

    private static func hardwareSerial(_ bsd: String) -> String? {
        let media = IOServiceGetMatchingService(kIOMainPortDefault, IOBSDNameMatching(kIOMainPortDefault, 0, bsd))
        guard media != 0 else { return nil }
        defer { IOObjectRelease(media) }
        let flags = IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        func property(_ key: String) -> AnyObject? {
            IORegistryEntrySearchCFProperty(media, kIOServicePlane, key as CFString, kCFAllocatorDefault, flags)
        }
        let device = property("Device Characteristics") as? [String: Any]
        let serial = ((device?["Serial Number"] as? String) ?? (property("USB Serial Number") as? String))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return serial.flatMap { $0.isEmpty ? nil : $0 }
    }

    static func available() throws -> [Self] {
        let list = try info(["list", "-plist", "external", "physical"])
        let root = try info(["info", "-plist", "/"])
        let stores = (root["APFSPhysicalStores"] as? [[String: Any]] ?? []).compactMap { $0["APFSPhysicalStore"] as? String }
        var disks = [Self]()
        for item in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let bsd = item["DeviceIdentifier"] as? String,
                  bsd.range(of: #"^disk[0-9]+$"#, options: .regularExpression) != nil,
                  bsd != (root["ParentWholeDisk"] as? String), bsd != (root["DeviceIdentifier"] as? String),
                  !stores.contains(where: { $0 == bsd || $0.hasPrefix(bsd + "s") }),
                  let details = try? info(["info", "-plist", bsd]),
                  details["Internal"] as? Bool == false, details["WholeDisk"] as? Bool == true,
                  details["DeviceBlockSize"] as? Int == 512, // libkrun presents 512-byte logical sectors
                  let bytes = details["TotalSize"] as? Int64, bytes > 0,
                  let registry = registryID(bsd) else { continue }
            var identity = details["DiskUUID"] as? String ?? details["VolumeUUID"] as? String
            for partition in item["Partitions"] as? [[String: Any]] ?? [] where identity == nil {
                if let child = partition["DeviceIdentifier"] as? String, child.hasPrefix(bsd + "s"),
                   let childInfo = try? info(["info", "-plist", child]) {
                    identity = childInfo["DiskUUID"] as? String ?? childInfo["VolumeUUID"] as? String
                }
            }
            // A partition UUID alone can belong to a clone. Without both hardware and media
            // identity, bind only to this live IOMedia object for this macOS boot.
            let key: String
            if let serial = hardwareSerial(bsd), let identity, let uuid = UUID(uuidString: identity) {
                key = "\(serial):\(uuid.uuidString):\(bytes)"
            }
            else {
                guard let boot = ReportBundle.sysctl("kern.bootsessionuuid") else { continue }
                key = "\(boot):\(registry):\(bytes)"
            }
            disks.append(Self(id: key, device: bsd, name: details["MediaName"] as? String ?? bsd,
                              bytes: bytes, registryID: registry, writable: details["Writable"] as? Bool == true))
        }
        return disks
    }

    static func openSelected(_ drive: AdditionalDrive) throws -> Int32 {
        let matches = try available().filter { $0.id == drive.physicalID }
        guard drive.kind == .raw, matches.count == 1, let disk = matches.first else {
            throw OptionError(String(localized: "Connect the selected external disk. Identical disk identities cannot be passed through."))
        }
        guard drive.readOnly || disk.writable else { throw OptionError(String(localized: "The external disk is read-only.")) }
        let path = "/dev/" + disk.device
        // O_EXLOCK maps to IOMedia's exclusive storage access, including against mounted partitions.
        // Use the buffered block node so virtio's 512-byte transfers need no raw-buffer alignment.
        let flags = (drive.readOnly ? O_RDONLY : O_RDWR) | O_EXLOCK | O_NONBLOCK
        var fd = open(path, flags | O_CLOEXEC)
        if fd < 0 && (errno == EACCES || errno == EPERM) {
            var sockets = [Int32](repeating: -1, count: 2)
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
                throw POSIXError(.ENFILE)
            }
            let sender = FileHandle(fileDescriptor: sockets[1], closeOnDealloc: true)
            defer { close(sockets[0]) }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            process.arguments = ["-stdoutpipe", "-o", String(flags), path]
            process.standardOutput = sender
            process.standardInput = FileHandle.nullDevice
            try process.run()
            try sender.close()
            fd = stella_receive_fd(sockets[0])
            process.waitUntilExit()
            if process.terminationStatus != 0, fd >= 0 { close(fd); fd = -1 }
        }
        guard fd >= 0 else {
            throw OptionError(String(localized: "Unmount all volumes on this disk in Disk Utility, keep it connected, and allow macOS access when prompted."))
        }
        var st = stat(), node = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFBLK, stat(path, &node) == 0,
              node.st_rdev == st.st_rdev, registryID(disk.device) == disk.registryID,
              stella_disk_size(fd) == disk.bytes else {
            close(fd)
            throw OptionError(String(localized: "The connected disk changed during authorization."))
        }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        return fd
    }
}
