import Foundation
import Darwin

enum PortCheck {
    /// True if something is already accepting TCP connections on `port` on this Mac.
    /// macOS lets a wildcard listener coexist with a loopback-only one, so Icecast
    /// can "start" on a busy port while localhost traffic still goes to the other app.
    /// Probing by connecting catches that case.
    static func isInUse(port: Int) -> Bool {
        accepts(family: AF_INET, port: port) || accepts(family: AF_INET6, port: port)
    }

    private static func accepts(family: Int32, port: Int) -> Bool {
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // Non-blocking connect to loopback with a short timeout.
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        var result: Int32
        if family == AF_INET {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = in_port_t(port).bigEndian
            a.sin_addr.s_addr = inet_addr("127.0.0.1")
            result = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = in_port_t(port).bigEndian
            a.sin6_addr = in6addr_loopback
            result = withUnsafePointer(to: &a) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }   // ECONNREFUSED etc. = nobody listening
        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, 300) > 0 else { return false }
        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
