import Foundation

/// Local IPC between `StayVibe --hook` processes and the running app: one JSON event per
/// connection over a Unix domain socket that only the current user can reach (0700 dir, 0600 socket).
public enum EventSocket {
    public static var defaultPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/StayVibe/events.sock").path
    }

    /// Sends one event. Returns false when the app isn't listening; never blocks for long.
    @discardableResult
    public static func send(_ event: HookEvent, to path: String = defaultPath) -> Bool {
        guard let data = try? JSONEncoder().encode(event) else { return false }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var timeout = timeval(tv_sec: 0, tv_usec: 200_000)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        guard withAddress(path, { connect(fd, $0, $1) }) == 0 else { return false }
        return data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } == data.count
    }

    /// Accepts events until deallocated; `handler` runs on the main queue.
    public final class Listener: @unchecked Sendable {
        private let fd: Int32
        private let source: DispatchSourceRead

        public init?(path: String = EventSocket.defaultPath, handler: @escaping @Sendable (HookEvent) -> Void) {
            let dir = (path as NSString).deletingLastPathComponent
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            unlink(path)
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0, withAddress(path, { bind(fd, $0, $1) }) == 0, listen(fd, 32) == 0 else {
                close(fd)
                return nil
            }
            chmod(path, 0o600)
            self.fd = fd
            source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global(qos: .userInitiated))
            source.setEventHandler {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { close(client) }
                var timeout = timeval(tv_sec: 1, tv_usec: 0)
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var data = Data()
                var buffer = [UInt8](repeating: 0, count: 8192)
                while case let n = read(client, &buffer, buffer.count), n > 0 { data.append(buffer, count: n) }
                guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else { return }
                DispatchQueue.main.async { handler(event) }
            }
            source.setCancelHandler { close(fd) }
            source.resume()
        }

        deinit { source.cancel() }
    }

    private static func withAddress(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> Int32) -> Int32 {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            let bytes = path.utf8.prefix(buffer.count - 1)
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
