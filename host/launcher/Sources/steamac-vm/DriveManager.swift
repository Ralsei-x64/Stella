import AppKit
import SwiftUI

private extension AdditionalDrive.Kind {
    var title: String {
        switch self {
        case .image: return String(localized: "Virtual disk")
        case .volume: return String(localized: "Mounted Mac volume")
        case .folder: return String(localized: "Mac folder")
        case .raw: return String(localized: "Raw physical disk")
        }
    }
    var symbol: String {
        switch self {
        case .image: return "internaldrive"
        case .volume: return "externaldrive"
        case .folder: return "folder"
        case .raw: return "externaldrive.connected.to.line.below"
        }
    }
}

struct DriveManager: View {
    @ObservedObject var settings: LauncherSettings
    @Environment(\.dismiss) private var dismiss
    @State private var adding = false
    @State private var deleting: AdditionalDrive?
    @State private var error = ""

    var body: some View {
        Group {
            if adding {
                DriveWizard(settings: settings) { adding = false }
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Additional drives").font(.title2.bold())
                    Text("Choose which drives SteamOS attaches on its next start.").foregroundStyle(.secondary)
                    List {
                        if settings.additionalDrives.isEmpty { Text("No additional drives").foregroundStyle(.secondary) }
                        ForEach($settings.additionalDrives) { $drive in
                            HStack(spacing: 12) {
                                Image(systemName: drive.kind.symbol).frame(width: 22)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(verbatim: drive.name).fontWeight(.semibold)
                                    Text(verbatim: [drive.kind.title, drive.sizeGiB.map { "\($0) GiB" },
                                                     drive.readOnly ? String(localized: "Read-only") : nil]
                                        .compactMap { $0 }.joined(separator: " · ")).font(.caption)
                                    if drive.kind != .raw {
                                        Text(verbatim: drive.mountPath).font(.caption.monospaced()).textSelection(.enabled)
                                    }
                                    if let reason = AdditionalDrive.skipped[drive.id] {
                                        Text(verbatim: reason).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Toggle("Attach on startup", isOn: $drive.enabled).toggleStyle(.checkbox)
                                Menu {
                                    if drive.kind == .image {
                                        if !FileManager.default.fileExists(atPath: drive.imageURL().path) {
                                            Button("Forget missing disk") { settings.additionalDrives.removeAll { $0.id == drive.id } }
                                        }
                                        Button("Show in Finder") {
                                            NSWorkspace.shared.activateFileViewerSelecting([drive.imageURL()])
                                        }
                                        Button("Move to Trash…", role: .destructive) { deleting = drive }
                                    } else {
                                        Button("Remove from Stella") { settings.additionalDrives.removeAll { $0.id == drive.id } }
                                    }
                                } label: { Image(systemName: "ellipsis.circle") }
                                .menuStyle(.borderlessButton).fixedSize().accessibilityLabel("Drive actions")
                            }.padding(.vertical, 4)
                        }
                    }.border(Color.secondary.opacity(0.2))
                    HStack {
                        Button("Add Drive…") { adding = true }
                            .disabled(settings.additionalDrives.count >= AdditionalDrive.maxCount)
                        Spacer()
                        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .padding(22).frame(width: 640, height: 415)
        .alert("Move this virtual disk to Trash?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
               presenting: deleting) { drive in
            Button("Cancel", role: .cancel) {}
            Button("Move to Trash", role: .destructive) {
                do {
                    try drive.trashImage()
                    settings.additionalDrives.removeAll { $0.id == drive.id }
                } catch is DiskLock.InUse {
                    error = String(localized: "Uncheck Attach on startup and restart SteamOS before deleting this disk.")
                } catch { self.error = error.localizedDescription }
            }
        } message: { drive in Text("The disk “\(drive.name)” and all of its contents will move to the Mac Trash.") }
        .alert("Drive unavailable", isPresented: Binding(get: { !error.isEmpty }, set: { if !$0 { error = "" } })) {
            Button("OK") {}
        } message: { Text(verbatim: error) }
    }
}

private struct DriveWizard: View {
    @ObservedObject var settings: LauncherSettings
    let finish: () -> Void
    @State private var step = 1
    @State private var kind = AdditionalDrive.Kind.image
    @State private var name = ""
    @State private var size = "64"
    @State private var source: URL?
    @State private var readOnly = true
    @State private var physical = [PhysicalDisk]()
    @State private var selectedDisk = ""
    @State private var searching = false
    @State private var error = ""
    @State private var id = UUID()

    private var disk: PhysicalDisk? { physical.first { $0.id == selectedDisk } }
    private var label: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: AdditionalDrive {
        var d = AdditionalDrive(id: id, kind: kind, name: label)
        d.sizeGiB = kind == .image ? Int(size) : nil
        d.readOnly = kind != .image && readOnly
        d.physicalID = kind == .raw ? selectedDisk : nil
        return d
    }
    private var valid: Bool {
        guard !label.isEmpty, label.count <= 64 else { return false }
        switch kind {
        case .image: return Int(size).map(AdditionalDrive.capacities.contains) ?? false
        case .volume, .folder: return source != nil
        case .raw: return disk != nil && (readOnly || disk?.writable == true)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(step == 1 ? String(localized: "Add a drive") : step == 2 ? kind.title : String(localized: "Review drive"))
                .font(.title2.bold())
            if step == 1 {
                Picker("Drive type", selection: $kind) {
                    ForEach(AdditionalDrive.Kind.allCases, id: \.self) { type in
                        Label(type.title, systemImage: type.symbol).tag(type)
                    }
                }.pickerStyle(.radioGroup)
            } else if step == 2 {
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                    GridRow { Text("Name"); TextField("Drive name", text: $name) }
                    if kind == .image {
                        GridRow {
                            Text("Capacity")
                            HStack { TextField("GiB", text: $size).frame(width: 86); Text("GiB (1–8192)") }
                        }
                    } else if kind == .raw {
                        GridRow {
                            Text("External disk")
                            HStack {
                                Picker("External disk", selection: $selectedDisk) {
                                    Text("Select a disk").tag("")
                                    ForEach(physical, id: \.device) { d in
                                        Text(verbatim: "\(d.name) · \(ByteCountFormatter.string(fromByteCount: d.bytes, countStyle: .file)) · \(d.device)").tag(d.id)
                                    }
                                }.labelsHidden()
                                Button("Refresh") { refresh() }.disabled(searching)
                            }
                        }
                    } else {
                        GridRow {
                            Text("Source")
                            HStack {
                                Button(kind == .volume ? String(localized: "Choose Volume…") : String(localized: "Choose Folder…")) { choose() }
                                if let source { Text(verbatim: source.path).lineLimit(1).truncationMode(.middle) }
                            }
                        }
                    }
                }
                if kind != .image { Toggle("Read-only", isOn: $readOnly) }
                switch kind {
                case .image: Text("The ext4 disk grows on your Mac as SteamOS writes data.")
                case .folder: Text("SteamOS accesses the selected folder’s files directly.")
                case .volume: Text("Select the root of a mounted external volume. Finder and SteamOS can both access its files.")
                case .raw: Text("Unmount the disk’s volumes in Disk Utility and keep it connected. SteamOS gets its partitions and sectors. Writable access allows SteamOS to erase the disk. Eligible disks use 512-byte logical sectors.")
                }
            } else {
                LabeledContent("Name", value: label)
                LabeledContent("Drive type", value: kind.title)
                if kind == .image { LabeledContent("Capacity", value: size + " GiB") }
                else {
                    LabeledContent("Source", value: source?.path ?? disk?.name ?? "")
                    LabeledContent("Access", value: readOnly ? String(localized: "Read-only") : String(localized: "Read and write"))
                }
                if kind != .raw { LabeledContent("SteamOS mount point", value: draft.mountPath) }
                Text("The drive will be attached the next time SteamOS starts.").foregroundStyle(.secondary)
            }
            if !error.isEmpty { Text(verbatim: error).foregroundStyle(.red).font(.callout) }
            Spacer()
            HStack {
                Button("Cancel", action: finish).keyboardShortcut(.cancelAction)
                Spacer()
                if step > 1 { Button("Back") { error = ""; step -= 1 } }
                Button(step == 3 ? String(localized: "Add Drive") : String(localized: "Continue")) {
                    if step == 3 { save(); return }
                    error = ""
                    step += 1
                    if step == 2 && kind == .raw { refresh() }
                }.keyboardShortcut(.defaultAction).disabled(step == 2 && !valid)
            }
        }
        .onChange(of: kind) {
            source = nil; selectedDisk = ""; name = ""; readOnly = true; error = ""
        }
        .onChange(of: selectedDisk) { if let disk { name = disk.name } }
    }

    private func refresh() {
        searching = true
        Task {
            do {
                let found = try await Task.detached { try PhysicalDisk.available() }.value
                physical = found
                if !found.contains(where: { $0.id == selectedDisk }) { selectedDisk = "" }
                error = found.isEmpty ? String(localized: "No eligible external disks found.") : ""
            } catch { self.error = error.localizedDescription }
            searching = false
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if kind == .volume { panel.directoryURL = URL(fileURLWithPath: "/Volumes") }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard kind != .volume || AdditionalDrive.isShareableVolume(url) else {
            error = String(localized: "Select the volume itself in /Volumes."); return
        }
        source = url
        name = url.lastPathComponent
        error = ""
    }

    private func save() {
        var drive = draft
        do {
            guard valid, settings.additionalDrives.count < AdditionalDrive.maxCount else { throw OptionError(String(localized: "Invalid drive configuration.")) }
            switch kind {
            case .image: try drive.createImage()
            case .volume, .folder:
                guard let source else { return }
                drive.bookmark = try source.bookmarkData()
                drive.volumeUUID = try source.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
                _ = try drive.resolveFolder()
                guard !settings.additionalDrives.contains(where: { (try? $0.resolveFolder())?.standardizedFileURL == source.standardizedFileURL }) else {
                    throw OptionError(String(localized: "This folder or volume is already configured."))
                }
            case .raw:
                guard !settings.additionalDrives.contains(where: { $0.physicalID == selectedDisk }) else {
                    throw OptionError(String(localized: "This physical disk is already configured."))
                }
            }
            settings.additionalDrives.append(drive)
            finish()
        } catch { self.error = error.localizedDescription }
    }
}
