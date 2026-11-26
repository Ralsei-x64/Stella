import AppKit
import Combine

/// WindowServer can keep compositing an overlay app's transparent windows after its UI disappears.
final class FullscreenOverlayApps {
    private static let alcove = "com.henrikruscon.Alcove"
    private struct ClosedApp: Codable {
        let pid: pid_t
        let url: URL

        var installedURL: URL? {
            if url.isFileURL, Bundle(url: url)?.bundleIdentifier == alcove { return url }
            return NSWorkspace.shared.urlForApplication(withBundleIdentifier: alcove)
        }
    }
    private static func marker(in directory: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent("closed-overlay-alcove.json")
    }

    private weak var window: NSWindow?
    private let marker: URL
    private var closed: ClosedApp?
    private var restoring = false
    private var wantsClosed = false
    private var observations = Set<AnyCancellable>()

    init(window: NSWindow, settings: LauncherSettings, directory: String) {
        self.window = window
        marker = Self.marker(in: directory)
        let workspace = NSWorkspace.shared.notificationCenter
        let changes = [NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
                       NSWindow.didChangeOcclusionStateNotification].map {
            NotificationCenter.default.publisher(for: $0, object: window)
        } + [workspace.publisher(for: NSWorkspace.activeSpaceDidChangeNotification)]
        Publishers.MergeMany(changes).map { _ in () }.prepend(())
            .combineLatest(settings.$closeOverlayApps)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, enabled in
                guard let self, let window = self.window else { return }
                let active = enabled && window.styleMask.contains(.fullScreen)
                    && window.isOnActiveSpace && window.occlusionState.contains(.visible)
                guard active != self.wantsClosed else { return }
                self.wantsClosed = active
                self.update()
            }.store(in: &observations)
        workspace.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] notification in
                guard let self, let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      self.closed?.pid == app.processIdentifier, !self.wantsClosed else { return }
                self.update()
            }.store(in: &observations)
    }

    private func update() {
        guard !restoring else { return }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: Self.alcove)
        if wantsClosed {
            guard closed == nil, let app = running.first, let url = app.bundleURL else { return }
            let record = ClosedApp(pid: app.processIdentifier, url: url)
            do {
                // A VM exit bypasses the AppKit termination callback. Let the supervisor restore the app.
                try JSONEncoder().encode(record).write(to: marker, options: .atomic)
            } catch { log("overlay apps: could not record Alcove for restoration: \(error)"); return }
            if app.terminate() { closed = record; log("overlay apps: requested Alcove quit for fullscreen") }
            else { clearRecord() }
        } else if let closed {
            // If the Space changed before the quit finished, the termination notification retries.
            if running.contains(where: { $0.processIdentifier == closed.pid }) { return }
            guard running.isEmpty, let url = closed.installedURL else { clearRecord(); return }
            restoring = true
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] _, error in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.restoring = false
                    if let error { log("overlay apps: could not reopen Alcove: \(error)"); return }
                    self.clearRecord()
                    log("overlay apps: reopened Alcove")
                    if self.wantsClosed { self.update() }
                }
            }
        }
    }

    private func clearRecord() {
        closed = nil
        try? FileManager.default.removeItem(at: marker)
    }

    /// Runs in the supervisor, including after a crashed or force-quit VM child.
    static func restoreAfterVMExit(directory: String) {
        let marker = marker(in: directory)
        guard let data = try? Data(contentsOf: marker),
              let closed = try? JSONDecoder().decode(ClosedApp.self, from: data) else { return }
        let deadline = Date(timeIntervalSinceNow: 3)
        while kill(closed.pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if NSRunningApplication.runningApplications(withBundleIdentifier: alcove).isEmpty,
           let url = closed.installedURL {
            // The supervisor doesn't run an AppKit event loop while waiting on the VM.
            let open = Process()
            open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            open.arguments = ["-g", "-a", url.path]
            do {
                try open.run()
                open.waitUntilExit()
                guard open.terminationStatus == 0 else { log("overlay apps: failed to reopen Alcove after VM exit"); return }
                log("overlay apps: reopened Alcove after VM exit")
            } catch { log("overlay apps: could not reopen Alcove: \(error)"); return }
        }
        try? FileManager.default.removeItem(at: marker)
    }
}
