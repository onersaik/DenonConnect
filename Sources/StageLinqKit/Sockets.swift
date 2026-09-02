// Sockets.swift
// Envoltorios mínimos sobre sockets BSD (Darwin) para UDP y TCP.
// Se usan sockets crudos en vez de Network.framework para tener control
// directo y predecible sobre broadcast UDP y framing manual de TCP.

import Foundation
#if canImport(Darwin)
import Darwin
#endif

public enum SocketError: Error, CustomStringConvertible {
    case creationFailed(String)
    case bindFailed(String)
    case connectFailed(String)
    case sendFailed(String)
    case recvFailed(String)
    case closed
    case timeout

    public var description: String {
        switch self {
        case .creationFailed(let s): return "no se pudo crear el socket: \(s)"
        case .bindFailed(let s): return "no se pudo hacer bind: \(s)"
        case .connectFailed(let s): return "no se pudo conectar: \(s)"
        case .sendFailed(let s): return "error al enviar: \(s)"
        case .recvFailed(let s): return "error al recibir: \(s)"
        case .closed: return "conexión cerrada"
        case .timeout: return "tiempo de espera agotado"
        }
    }
}

private func lastErrnoString() -> String {
    String(cString: strerror(errno))
}

/// Socket UDP simple: escucha en un puerto y permite enviar broadcast.
public final class UDPSocket {
    private let fd: Int32

    public init(listenPort: UInt16?) throws {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw SocketError.creationFailed(lastErrnoString()) }

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #if canImport(Darwin)
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &reuse, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var broadcastEnable: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_BROADCAST, &broadcastEnable, socklen_t(MemoryLayout<Int32>.size))
        // Waveform RGB en TestLink ~45 KB; el default de recvfrom era 8 KB y recortaba el JSON.
        var bufBytes: Int32 = 256 * 1024
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufBytes, socklen_t(MemoryLayout<Int32>.size))

        if let port = listenPort {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            addr.sin_addr.s_addr = INADDR_ANY
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard result == 0 else {
                // Darwin. explícito: sin él resolvería al método close() de esta clase.
                Darwin.close(fd)
                throw SocketError.bindFailed(lastErrnoString())
            }
        }

        // Timeout de lectura para poder revisar cancelación periódicamente.
        var tv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func send(_ data: Data, to host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)

        _ = data.withUnsafeBytes { rawBuf -> Int in
            withUnsafePointer(to: &addr) { ptr -> Int in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                    sendto(fd, rawBuf.baseAddress, data.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    /// Recibe un datagrama. Devuelve nil si expira el timeout (para poder revisar cancelación).
    public func receive() -> (data: Data, fromIP: String)? {
        var buf = [UInt8](repeating: 0, count: 65536)
        var fromAddr = sockaddr_in()
        var fromLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        let n = withUnsafeMutablePointer(to: &fromAddr) { fp -> Int in
            fp.withMemoryRebound(to: sockaddr.self, capacity: 1) { sp in
                recvfrom(fd, &buf, buf.count, 0, sp, &fromLen)
            }
        }
        guard n > 0 else { return nil }

        var ipBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var srcAddr = fromAddr.sin_addr
        inet_ntop(AF_INET, &srcAddr, &ipBuf, socklen_t(INET_ADDRSTRLEN))
        let ip = String(cString: ipBuf)

        return (Data(buf[0..<n]), ip)
    }

    public func close() {
        #if canImport(Darwin)
        Darwin.close(fd)
        #endif
    }
}

/// Socket TCP de escucha, para el simulador de reproductor.
public final class TCPListener {
    private let fd: Int32
    public let port: UInt16

    public init(port: UInt16) throws {
        // Trabajamos con un descriptor local: si el closure usara la propiedad
        // capturaría self antes de estar todo inicializado, y eso no compila.
        let listenFD = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard listenFD >= 0 else { throw SocketError.creationFailed(lastErrnoString()) }

        var reuse: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bound = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            Darwin.close(listenFD)
            throw SocketError.bindFailed(lastErrnoString())
        }
        guard listen(listenFD, 8) == 0 else {
            Darwin.close(listenFD)
            throw SocketError.bindFailed(lastErrnoString())
        }

        self.fd = listenFD
        self.port = port
    }

    /// Espera una conexión entrante. Devuelve nil si expira el tiempo, para
    /// poder revisar la cancelación entre intentos.
    public func accept(timeoutSeconds: Int = 1) -> TCPConnection? {
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pfd, 1, Int32(timeoutSeconds * 1000)) > 0 else { return nil }
        let client = Darwin.accept(fd, nil, nil)
        guard client >= 0 else { return nil }
        return TCPConnection(acceptedFD: client)
    }

    public func close() {
        Darwin.close(fd)
    }
}

/// Conexión TCP simple, bloqueante, con lectura por buffer acumulado.
public final class TCPConnection {
    private var fd: Int32 = -1
    public private(set) var isOpen = false

    /// Envuelve un descriptor ya aceptado por un TCPListener.
    public init(acceptedFD: Int32) {
        fd = acceptedFD
        isOpen = true
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public init(host: String, port: UInt16, timeoutSeconds: Int = 8) throws {
        fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError.creationFailed(lastErrnoString()) }

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            close()
            throw SocketError.connectFailed("dirección IP inválida: \(host)")
        }

        // Socket no bloqueante para poder aplicar timeout de conexión.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if connectResult != 0 && errno != EINPROGRESS {
            close()
            throw SocketError.connectFailed(lastErrnoString())
        }

        if connectResult != 0 {
            // Usamos poll() (en vez de select()/fd_set, cuya representación en
            // Swift es incómoda) para esperar a que el socket quede escribible
            // o al timeout.
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let pollResult = poll(&pfd, 1, Int32(timeoutSeconds * 1000))
            guard pollResult > 0 else {
                close()
                throw SocketError.timeout
            }
            var soError: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
            guard soError == 0 else {
                close()
                throw SocketError.connectFailed(String(cString: strerror(soError)))
            }
        }

        // Volver a modo bloqueante con timeout de lectura, más simple para el resto del ciclo de vida.
        _ = fcntl(fd, F_SETFL, flags)
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        isOpen = true
    }

    public func setReadTimeout(seconds: Int) {
        setReadTimeout(milliseconds: max(0, seconds) * 1000)
    }

    public func setReadTimeout(milliseconds: Int) {
        let ms = max(0, milliseconds)
        var tv = timeval(tv_sec: ms / 1000, tv_usec: suseconds_t((ms % 1000) * 1000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func send(_ data: Data) throws {
        guard isOpen else { throw SocketError.closed }
        let sent = data.withUnsafeBytes { rawBuf -> Int in
            Darwin.send(fd, rawBuf.baseAddress, data.count, 0)
        }
        guard sent == data.count else { throw SocketError.sendFailed(lastErrnoString()) }
    }

    /// Lee hasta `maxBytes`, o nil si expira el timeout de lectura (permite revisar cancelación).
    /// Lanza SocketError.closed si el peer cerró la conexión.
    public func receive(maxBytes: Int = 8192) throws -> Data? {
        guard isOpen else { throw SocketError.closed }
        var buf = [UInt8](repeating: 0, count: maxBytes)
        let n = recv(fd, &buf, maxBytes, 0)
        if n > 0 {
            return Data(buf[0..<n])
        } else if n == 0 {
            isOpen = false
            throw SocketError.closed
        } else {
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return nil // timeout de lectura, no es un error real
            }
            isOpen = false
            throw SocketError.recvFailed(lastErrnoString())
        }
    }

    public func close() {
        if fd >= 0 {
            #if canImport(Darwin)
            Darwin.close(fd)
            #endif
        }
        isOpen = false
    }

    deinit { close() }
}
