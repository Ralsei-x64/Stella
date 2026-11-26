import Foundation
import Darwin
import Network

/// Rich Presence uses Discord's local desktop socket. All connection state lives on one queue.
final class DiscordPresence {
    // Public icon of Stella’s registered Discord application.
    private static let logo = "https://cdn.discordapp.com/app-icons/1575258761285607464/b892160de275a2d8a5fb7a1270a7d57b.png?size=256"

    struct Activity: Equatable {
        let appid: Int?
        let title: String
        let start: Int64

        init?(title: String, since: Date, appid: Int? = nil) {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            // Discord limits activity text to 128 bytes. Keep whole UTF-8 scalars.
            var text = ""
            for scalar in trimmed.unicodeScalars {
                guard text.utf8.count + scalar.utf8.count <= 128 else { break }
                text.unicodeScalars.append(scalar)
            }
            self.appid = appid
            self.title = text
            start = Int64(since.timeIntervalSince1970)
        }
    }

    private let applicationID: String?
    private let repository: URL
    private let directories: [String]
    private let fetchCover: (Int, @escaping (URL?) -> Void) -> Void
    private var covers: [Int: URL] = [:]
    private var pendingCovers: Set<Int> = []
    private var retryCoverAfter: [Int: Date] = [:]
    private let queue = DispatchQueue(label: "Stella.DiscordPresence", qos: .utility)
    private var connection: NWConnection?
    private var ready = false
    private var desired: Activity?
    private var clearNonce: String?
    private var retry: DispatchWorkItem?
    private var lastPath: String?

    init(applicationID: String?, repository: URL, directories: [String] = DiscordPresence.defaultDirectories,
         fetchCover: @escaping (Int, @escaping (URL?) -> Void) -> Void = SteamCoverArt.fetch) {
        self.applicationID = applicationID
        self.repository = repository
        self.directories = directories
        self.fetchCover = fetchCover
    }

    func setActivity(_ activity: Activity?) {
        queue.async {
            guard self.desired != activity else { return }
            self.desired = activity
            if self.ready {
                self.publish()
            } else if activity == nil {
                self.disconnect()
            } else if self.connection == nil && self.retry == nil {
                self.connect()
            }
        }
    }

    private static var defaultDirectories: [String] {
        let env = ProcessInfo.processInfo.environment
        return [env["XDG_RUNTIME_DIR"], env["TMPDIR"], env["TMP"], env["TEMP"],
                           FileManager.default.temporaryDirectory.path, "/tmp"].compactMap { $0 }
    }

    private func socketPaths() -> [String] {
        var paths: [String] = []
        for directory in directories where !directory.isEmpty {
            for index in 0..<10 {
                let path = URL(fileURLWithPath: directory).appendingPathComponent("discord-ipc-\(index)").path
                guard !paths.contains(path) else { continue }
                var info = stat()
                if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == geteuid() {
                    paths.append(path)
                }
            }
        }
        return paths
    }

    private func connect() {
        guard desired != nil, let applicationID, !applicationID.isEmpty else { return }
        let paths = socketPaths()
        guard !paths.isEmpty else { scheduleRetry(); return }
        // Try the next socket on a failure, including when a crashed Discord left one behind.
        let index = lastPath.flatMap { paths.firstIndex(of: $0) }.map { ($0 + 1) % paths.count } ?? 0
        let path = paths[index]
        lastPath = path
        let ipc = NWConnection(to: .unix(path: path), using: .tcp)
        connection = ipc
        ipc.stateUpdateHandler = { [weak self, weak ipc] state in
            guard let self, let ipc, self.connection === ipc else { return }
            switch state {
            case .ready:
                self.send(0, json: ["v": 1, "client_id": applicationID], on: ipc)
                self.readHeader(on: ipc)
            case .failed, .waiting, .cancelled:
                self.disconnect()
            default: break
            }
        }
        ipc.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak ipc] in
            guard let self, let ipc, self.connection === ipc, !self.ready else { return }
            self.disconnect()
        }
    }

    private func disconnect() {
        connection?.cancel()
        connection = nil
        ready = false
        clearNonce = nil
        retry?.cancel()
        retry = nil
        if desired != nil { scheduleRetry() }
    }

    private func scheduleRetry() {
        let job = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.retry = nil
            self.connect()
        }
        retry = job
        queue.asyncAfter(deadline: .now() + 10, execute: job)
    }

    private func assets(for activity: Activity) -> [String: String] {
        if let id = activity.appid {
            if let cover = covers[id] {
                return ["large_image": cover.absoluteString, "large_text": activity.title,
                        "small_image": Self.logo, "small_text": "Stella", "small_url": repository.absoluteString]
            }
            if (retryCoverAfter[id] ?? .distantPast) <= Date(), pendingCovers.insert(id).inserted {
                fetchCover(id) { [weak self] url in
                    guard let self else { return }
                    self.queue.async {
                        self.pendingCovers.remove(id)
                        guard let url else { self.retryCoverAfter[id] = Date().addingTimeInterval(60); return }
                        self.covers[id] = url
                        if self.desired?.appid == id && self.ready { self.publish() }
                    }
                }
            }
        }
        return ["large_image": Self.logo, "large_text": "Stella", "large_url": repository.absoluteString]
    }

    private func publish() {
        guard let ipc = connection, ready else { return }
        let nonce = UUID().uuidString
        var args: [String: Any] = ["pid": getpid()]
        if let desired {
            clearNonce = nil
            args["activity"] = [
                "type": 0, "name": desired.title,
                "state": "Playing through Stella", "state_url": repository.absoluteString,
                "timestamps": ["start": desired.start], "assets": assets(for: desired),
                "buttons": [["label": "Stella on GitHub", "url": repository.absoluteString]]
            ] as [String: Any]
        } else {
            clearNonce = nonce
            args["activity"] = NSNull()
            queue.asyncAfter(deadline: .now() + 5) { [weak self] in
                if self?.clearNonce == nonce { self?.disconnect() }
            }
        }
        send(1, json: ["cmd": "SET_ACTIVITY", "args": args, "nonce": nonce], on: ipc)
    }

    private func send(_ opcode: UInt32, json: [String: Any], on ipc: NWConnection) {
        guard let body = try? JSONSerialization.data(withJSONObject: json) else { return }
        send(opcode, body: body, on: ipc)
    }

    private func send(_ opcode: UInt32, body: Data, on ipc: NWConnection) {
        var packet = Data()
        for var word in [opcode.littleEndian, UInt32(body.count).littleEndian] {
            withUnsafeBytes(of: &word) { packet.append(contentsOf: $0) }
        }
        packet.append(body)
        ipc.send(content: packet, completion: .contentProcessed { [weak self, weak ipc] error in
            if error != nil, let self, let ipc, self.connection === ipc { self.disconnect() }
        })
    }

    private func readHeader(on ipc: NWConnection) {
        read(8, on: ipc) { header in
            let (opcode, length) = header.withUnsafeBytes {
                (UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)),
                 UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)))
            }
            guard length <= 64 * 1024 else { self.disconnect(); return }
            self.read(Int(length), on: ipc) { body in
                switch opcode {
                case 1:
                    guard let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
                        self.disconnect(); return
                    }
                    if message["evt"] as? String == "ERROR" { self.disconnect(); return }
                    if message["cmd"] as? String == "DISPATCH", message["evt"] as? String == "READY", !self.ready {
                        self.ready = true
                        self.lastPath = nil
                        self.publish()
                    } else if let nonce = self.clearNonce, message["nonce"] as? String == nonce {
                        self.disconnect(); return
                    }
                case 3: self.send(4, body: body, on: ipc) // PING → PONG
                case 4: break
                default: self.disconnect(); return
                }
                self.readHeader(on: ipc)
            }
        }
    }

    private func read(_ count: Int, on ipc: NWConnection, then: @escaping (Data) -> Void) {
        if count == 0 { then(Data()); return }
        ipc.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, _, error in
            guard let self, self.connection === ipc else { return }
            guard error == nil, let data, data.count == count else { self.disconnect(); return }
            then(data)
        }
    }
}

/// Newer Steam library covers have content hashes in their paths. Valve's store metadata
/// supplies both these filenames and the classic library_600x900.jpg names.
enum SteamCoverArt {
    static func fetch(_ appid: Int, completion: @escaping (URL?) -> Void) {
        var api = URLComponents(string: "https://api.steampowered.com/IStoreBrowseService/GetItems/v1/")!
        let input = #"{"ids":[{"appid":\#(appid)}],"context":{"language":"english","country_code":"US"},"data_request":{"include_assets":true}}"#
        api.queryItems = [URLQueryItem(name: "input_json", value: input)]
        guard let url = api.url else { completion(nil); return }
        URLSession.shared.dataTask(with: URLRequest(url: url, timeoutInterval: 5)) { data, response, _ in
            guard (response as? HTTPURLResponse)?.statusCode == 200, let data else { completion(nil); return }
            completion(imageURL(for: appid, data: data))
        }.resume()
    }

    static func imageURL(for appid: Int, data: Data) -> URL? {
        struct Reply: Decodable {
            struct Response: Decodable {
                struct Item: Decodable {
                    let appid: Int
                    struct Assets: Decodable {
                        let library_capsule: String?
                        let header: String?
                    }
                    let assets: Assets?
                }
                let store_items: [Item]
            }
            let response: Response
        }
        guard let result = try? JSONDecoder().decode(Reply.self, from: data),
              let assets = result.response.store_items.first(where: { $0.appid == appid })?.assets else { return nil }
        let base = URL(string: "https://shared.fastly.steamstatic.com/store_item_assets/steam/apps/\(appid)/")!
        for case let path? in [assets.library_capsule, assets.header] where !path.isEmpty {
            return base.appendingPathComponent(path)
        }
        return nil
    }
}
