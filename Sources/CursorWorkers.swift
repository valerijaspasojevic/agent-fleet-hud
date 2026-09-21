import Foundation

/// Reads the real status of a Cursor worker from the socket it already exposes.
///
/// Each `cursor-agent worker start` process is launched with
/// `--worker-api-socket <path>`, and that socket serves a Connect-RPC service,
/// `agent.v1.PrivateWorkerApiService`, over cleartext HTTP/2. Its own proto
/// descriptor declares the states:
///
///     UNSPECIFIED(0) · DISCONNECTED(1) · READY(2) · CLAIMED(3)
///
/// `CLAIMED` means an agent has taken the worker and is running through it;
/// `READY` means it is connected and idle. That is the difference between an
/// agent actually working and a worker sitting there, which nothing else on
/// this machine will tell you.
///
/// What it still cannot tell you is whether an agent is waiting on *you*. A
/// Cursor agent is a cloud agent: while it waits for your answer nothing
/// executes locally, so the worker is honestly `READY`. That state lives on
/// Cursor's servers and is not readable here.
enum CursorWorkers {
    enum Status: String {
        case ready = "PRIVATE_WORKER_STATUS_READY"
        case claimed = "PRIVATE_WORKER_STATUS_CLAIMED"
        case disconnected = "PRIVATE_WORKER_STATUS_DISCONNECTED"
        case unspecified = "PRIVATE_WORKER_STATUS_UNSPECIFIED"

        /// An agent is actively running through this worker.
        var isWorking: Bool { self == .claimed }
    }

    struct Reading {
        let status: Status
        let connected: Bool
        let workerId: String?
    }

    private static let refreshInterval: TimeInterval = 8
    private static var cache: [String: (Reading, Date)] = [:]
    private static let lock = NSLock()

    /// Cached per socket: the panel polls every 3s and a worker's status does
    /// not move faster than this.
    static func status(socketPath: String) -> Reading? {
        lock.lock()
        if let (reading, at) = cache[socketPath], Date().timeIntervalSince(at) < refreshInterval {
            lock.unlock()
            return reading
        }
        lock.unlock()

        let fresh = fetch(socketPath: socketPath)
        lock.lock()
        if let fresh { cache[socketPath] = (fresh, Date()) }
        lock.unlock()
        return fresh
    }

    private static func fetch(socketPath: String) -> Reading? {
        // WatchStatus is a server-streaming method that never ends, so the
        // first message is read and the connection dropped.
        guard let payload = H2.callConnect(
            socketPath: socketPath,
            path: "/agent.v1.PrivateWorkerApiService/WatchStatus",
            contentType: "application/connect+json",
            body: envelope(Data("{}".utf8))
        ) else { return nil }

        guard let json = unwrapEnvelope(payload),
              let obj = try? JSONSerialization.jsonObject(with: json) as? [String: Any]
        else { return nil }

        let raw = obj["status"] as? String ?? ""
        return Reading(status: Status(rawValue: raw) ?? .unspecified,
                       connected: obj["connected"] as? Bool ?? false,
                       workerId: obj["workerId"] as? String)
    }

    /// Connect's streaming framing: one flag byte, then a big-endian length.
    private static func envelope(_ body: Data) -> Data {
        var out = Data([0])
        var length = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }

    private static func unwrapEnvelope(_ data: Data) -> Data? {
        guard data.count >= 5 else { return nil }
        let lengthBytes = data[(data.startIndex + 1)..<(data.startIndex + 5)]
        let length = lengthBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let start = data.startIndex + 5
        let end = min(data.endIndex, start + Int(length))
        guard start < end else { return nil }
        return data[start..<end]
    }
}

// MARK: - Minimal HTTP/2

/// Just enough cleartext HTTP/2 to make one Connect call and read the first
/// response body frame.
///
/// Hand-rolled because the alternative is a dependency: URLSession cannot open
/// a unix socket, and this app has no package manifest. Only the client half
/// is needed, and only for one request per connection, which keeps it small —
/// response headers are skipped rather than decoded, so no HPACK *decoder* is
/// required, and requests use literal header fields without indexing, so no
/// dynamic table or Huffman coding is needed either.
private enum H2 {
    static func callConnect(socketPath: String, path: String,
                            contentType: String, body: Data) -> Data? {
        guard let sock = connect(socketPath) else { return nil }
        defer { close(sock) }

        var out = Data("PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n".utf8)
        out.append(frame(type: 0x04, flags: 0, stream: 0, payload: Data()))       // SETTINGS
        out.append(frame(type: 0x04, flags: 0x01, stream: 0, payload: Data()))    // SETTINGS ACK
        out.append(frame(type: 0x01, flags: 0x04, stream: 1,                      // HEADERS
                         payload: headerBlock(path: path, contentType: contentType)))
        out.append(frame(type: 0x00, flags: 0x01, stream: 1, payload: body))      // DATA, END_STREAM
        guard send(sock, out) else { return nil }

        var buffer = Data()
        // Bounded so a silent or chatty peer cannot stall the poll.
        for _ in 0..<64 {
            guard let chunk = receive(sock), !chunk.isEmpty else { break }
            buffer.append(chunk)
            if let payload = firstDataFrame(in: buffer) { return payload }
        }
        return nil
    }

    // MARK: Framing

    private static func frame(type: UInt8, flags: UInt8, stream: UInt32, payload: Data) -> Data {
        var out = Data()
        let length = UInt32(payload.count)
        out.append(UInt8((length >> 16) & 0xff))
        out.append(UInt8((length >> 8) & 0xff))
        out.append(UInt8(length & 0xff))
        out.append(type)
        out.append(flags)
        var id = stream.bigEndian
        withUnsafeBytes(of: &id) { out.append(contentsOf: $0) }
        out.append(payload)
        return out
    }

    /// Walks complete frames and returns the first DATA payload on stream 1.
    private static func firstDataFrame(in buffer: Data) -> Data? {
        var index = buffer.startIndex
        while index + 9 <= buffer.endIndex {
            let length = Int(buffer[index]) << 16 | Int(buffer[index + 1]) << 8 | Int(buffer[index + 2])
            let type = buffer[index + 3]
            let stream = UInt32(buffer[index + 5]) << 24 | UInt32(buffer[index + 6]) << 16
                | UInt32(buffer[index + 7]) << 8 | UInt32(buffer[index + 8])
            let start = index + 9
            guard start + length <= buffer.endIndex else { return nil }
            if type == 0x00, stream & 0x7fffffff == 1, length > 0 {
                return buffer[start..<(start + length)]
            }
            index = start + length
        }
        return nil
    }

    // MARK: HPACK (encoder only)

    private static func headerBlock(path: String, contentType: String) -> Data {
        var out = Data()
        for (name, value) in [
            (":method", "POST"),
            (":scheme", "http"),
            (":authority", "localhost"),
            (":path", path),
            ("content-type", contentType),
            ("connect-protocol-version", "1"),
            ("te", "trailers"),
        ] {
            // 0x00: literal header field without indexing, new name.
            out.append(0x00)
            out.append(contentsOf: literal(name))
            out.append(contentsOf: literal(value))
        }
        return out
    }

    /// Length-prefixed, not Huffman-coded. Header values here are short, so the
    /// 7-bit length prefix never needs its continuation form.
    private static func literal(_ text: String) -> Data {
        let bytes = Data(text.utf8)
        precondition(bytes.count < 127, "header too long for the short form")
        return Data([UInt8(bytes.count)]) + bytes
    }

    // MARK: Socket

    private static func connect(_ path: String) -> Int32? {
        let sock = socket(AF_UNIX, SOCK_STREAM, 0)
        guard sock >= 0 else { return nil }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else {
            close(sock)
            return nil
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
        }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(sock, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(sock, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock, $0, size) }
        }
        guard result == 0 else {
            close(sock)
            return nil
        }
        return sock
    }

    private static func send(_ sock: Int32, _ data: Data) -> Bool {
        var remaining = data
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { raw in
                Darwin.send(sock, raw.baseAddress, raw.count, 0)
            }
            guard written > 0 else { return false }
            remaining = remaining.dropFirst(written)
        }
        return true
    }

    private static func receive(_ sock: Int32) -> Data? {
        var chunk = [UInt8](repeating: 0, count: 8192)
        let read = recv(sock, &chunk, chunk.count, 0)
        guard read > 0 else { return nil }
        return Data(chunk[0..<read])
    }
}
