#!/usr/bin/env python3
"""Exercise Stella's desktop RPC client using a private Discord IPC socket on macOS."""
import json
import os
from pathlib import Path
import select
import socket
import struct
import subprocess
import tempfile

SOURCE = Path(__file__).resolve().parents[1] / "Sources/steamac-vm/DiscordPresence.swift"
REPOSITORY = "https://github.com/Ralsei-x64/Stella"
FIXTURE = """
import Foundation
let client = DiscordPresence(applicationID: "123456789012345678",
                             repository: URL(string: CommandLine.arguments[1])!,
                             directories: [CommandLine.arguments[2]], fetchCover: { id, done in
    let item: [String: Any] = ["appid": id, "assets": ["library_capsule": "abc/library_capsule.jpg"]]
    let data = try! JSONSerialization.data(withJSONObject: ["response": ["store_items": [item]]])
    done(SteamCoverArt.imageURL(for: id, data: data))
})
while let line = readLine() {
    let parts = line.split(separator: "|", maxSplits: 2)
    if parts.count >= 2, let start = Double(parts[0]) {
        client.setActivity(.init(title: String(parts.last!), since: Date(timeIntervalSince1970: start),
                                 appid: parts.count == 3 ? Int(parts[1]) : nil))
    } else {
        client.setActivity(nil)
    }
}
"""


def read_exact(peer, count):
    data = bytearray()
    while len(data) < count:
        chunk = peer.recv(count - len(data))
        assert chunk, "Unexpected end of IPC stream"
        data.extend(chunk)
    return data


def receive(peer):
    opcode, size = struct.unpack("<II", read_exact(peer, 8))
    return opcode, json.loads(read_exact(peer, size))


def send(peer, opcode, message):
    body = json.dumps(message).encode()
    frame = struct.pack("<II", opcode, len(body)) + body
    peer.sendall(frame[:3])
    peer.sendall(frame[3:11])
    peer.sendall(frame[11:])


def handshake(listener):
    peer, _ = listener.accept()
    peer.settimeout(5)
    assert receive(peer) == (0, {"v": 1, "client_id": "123456789012345678"})
    send(peer, 3, {"echo": "hello"})
    assert receive(peer) == (4, {"echo": "hello"})
    send(peer, 1, {"cmd": "DISPATCH", "evt": "READY"})
    return peer


def activity(peer, pid, title, start, cover_id=None):
    opcode, msg = receive(peer)
    assert opcode == 1 and msg["cmd"] == "SET_ACTIVITY" and msg["args"]["pid"] == pid
    card = msg["args"]["activity"]
    assert card["type"] == 0 and card["name"] == title and "details" not in card
    assert card.get("status_display_type", 0) == 0 and card["state"] == "Playing through Stella"
    assert card["state_url"] == REPOSITORY
    assets = card["assets"]
    if cover_id is None:
        assert "cdn.discordapp.com/app-icons/" in assets["large_image"]
        assert "small_image" not in assets
    else:
        assert assets["large_image"].endswith(f"/apps/{cover_id}/abc/library_capsule.jpg")
        assert "cdn.discordapp.com/app-icons/" in assets["small_image"] and assets["small_text"] == "Stella"
    assert card["timestamps"] == {"start": start}
    assert card["buttons"] == [{"label": "Stella on GitHub", "url": REPOSITORY}]


def test(tmp):
    source, binary = Path(tmp) / "main.swift", Path(tmp) / "fixture"
    source.write_text(FIXTURE)
    subprocess.run(["xcrun", "swiftc", str(SOURCE), str(source), "-o", str(binary)], check=True)
    with socket.socket(socket.AF_UNIX) as listener:
        listener.bind(os.path.join(tmp, "discord-ipc-0"))
        listener.listen()
        listener.settimeout(20)
        with subprocess.Popen([binary, REPOSITORY, tmp], stdin=subprocess.PIPE, text=True) as client:
            def update(text):
                print(text, file=client.stdin, flush=True)

            try:
                update("50|Steam Library")
                with handshake(listener) as peer:
                    activity(peer, client.pid, "Steam Library", 50)
                    update("100|1237970|Titanfall 2")
                    activity(peer, client.pid, "Titanfall 2", 100)
                    activity(peer, client.pid, "Titanfall 2", 100, 1237970)
                    update("100|1237970|Titanfall 2")
                    assert not select.select([peer], [], [], 0.1)[0]
                    update("200|DOOM Eternal")
                    activity(peer, client.pid, "DOOM Eternal", 200)

                with handshake(listener) as peer:
                    activity(peer, client.pid, "DOOM Eternal", 200)
                    update("clear")
                    _, cleared = receive(peer)
                    assert cleared["args"]["activity"] is None
                    update("300|" + "火" * 50)
                    activity(peer, client.pid, "火" * 42, 300)
                    send(peer, 1, {"cmd": "SET_ACTIVITY", "nonce": cleared["nonce"]})
                    update("400|Hades")
                    activity(peer, client.pid, "Hades", 400)
                    update("clear")
                    _, cleared = receive(peer)
                    assert cleared["args"]["activity"] is None
                    send(peer, 1, {"cmd": "SET_ACTIVITY", "nonce": cleared["nonce"]})
                    assert peer.recv(1) == b""
            finally:
                client.stdin.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="stella-rpc-", dir="/tmp") as tmp:
        test(tmp)
    print("Discord Rich Presence smoke test passed.")
