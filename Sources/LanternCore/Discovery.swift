import Foundation
import Darwin

public struct LANInterface: Identifiable, Hashable {
    public let name: String
    public let address: String
    public let mask: UInt32
    public var id: String { "\(name)-\(address)" }
    public var label: String { "\(name) · \(address)" }

    public static func available() -> [LANInterface] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0 else { return [] }
        defer { freeifaddrs(pointer) }
        var result: [LANInterface] = []
        var current = pointer
        while let entry = current {
            defer { current = entry.pointee.ifa_next }
            let value = entry.pointee
            let name = String(cString: value.ifa_name)
            guard name.hasPrefix("en"), value.ifa_flags & UInt32(IFF_UP) != 0, let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_INET), let mask = value.ifa_netmask else { continue }
            let ip = UnsafeRawPointer(address).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
            let netmask = UnsafeRawPointer(mask).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr.s_addr
            var copy = ip
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN))
            result.append(LANInterface(name: name, address: String(cString: buffer), mask: netmask))
        }
        return result.sorted { $0.name < $1.name }
    }
}

final class Discovery {
    let queue: DispatchQueue
    let interface: LANInterface
    let uuid: String
    let location: String
    let log: (String) -> Void
    var socketFD: Int32 = -1
    var source: DispatchSourceRead?
    var timer: DispatchSourceTimer?
    var pending = 0
    var generation = UUID()
    var types: [String] { ["upnp:rootdevice", "uuid:\(uuid)", "urn:schemas-upnp-org:device:MediaServer:1", "urn:schemas-upnp-org:service:ContentDirectory:1", "urn:schemas-upnp-org:service:ConnectionManager:1"] }

    init(queue: DispatchQueue, interface: LANInterface, uuid: String, location: String, log: @escaping (String) -> Void) {
        self.queue = queue; self.interface = interface; self.uuid = uuid; self.location = location; self.log = log
    }

    func start() throws {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw POSIXError(.ENOTSOCK) }
        socketFD = fd
        do {
            var yes: Int32 = 1
            guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0,
                  setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout.size(ofValue: yes))) == 0 else { throw POSIXError(.EADDRINUSE) }
            var local = sockaddr_in()
            local.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); local.sin_family = sa_family_t(AF_INET); local.sin_port = UInt16(1900).bigEndian
            let bound = withUnsafePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EADDRINUSE) }
            var membership = ip_mreq()
            membership.imr_multiaddr.s_addr = inet_addr("239.255.255.250")
            membership.imr_interface.s_addr = inet_addr(interface.address)
            guard setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &membership, socklen_t(MemoryLayout<ip_mreq>.size)) == 0 else { throw POSIXError(.ENETUNREACH) }
            var outbound = membership.imr_interface
            guard setsockopt(fd, IPPROTO_IP, IP_MULTICAST_IF, &outbound, socklen_t(MemoryLayout<in_addr>.size)) == 0 else { throw POSIXError(.ENETUNREACH) }
            var ttl: UInt8 = 2
            setsockopt(fd, IPPROTO_IP, IP_MULTICAST_TTL, &ttl, 1)
            guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { throw POSIXError(.EIO) }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            self.source = source
            source.setEventHandler { [weak self] in self?.receive() }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            self.timer = timer
            timer.schedule(deadline: .now(), repeating: 60)
            timer.setEventHandler { [weak self] in self?.announce(alive: true) }
            timer.resume()
        } catch {
            Darwin.close(fd); socketFD = -1
            throw error
        }
    }

    func stop() {
        guard socketFD >= 0 else { return }
        announce(alive: false)
        generation = UUID()
        timer?.cancel(); timer = nil
        source?.cancel(); source = nil
        socketFD = -1
    }

    func send(_ text: String, to address: sockaddr_in) {
        guard socketFD >= 0 else { return }
        var address = address
        let bytes = Array(text.utf8)
        bytes.withUnsafeBytes { payload in
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(socketFD, payload.baseAddress, payload.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        }
    }

    func usn(_ type: String) -> String { type == "uuid:\(uuid)" ? type : "uuid:\(uuid)::\(type)" }

    func announce(alive: Bool) {
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = UInt16(1900).bigEndian; destination.sin_addr.s_addr = inet_addr("239.255.255.250")
        for type in types {
            send("NOTIFY * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nCACHE-CONTROL: max-age=180\r\nLOCATION: \(location)\r\nNT: \(type)\r\nNTS: ssdp:\(alive ? "alive" : "byebye")\r\nSERVER: Darwin/1.0 UPnP/1.0 Lantern/0.1\r\nUSN: \(usn(type))\r\n\r\n", to: destination)
        }
    }

    func receive() {
        for _ in 0..<32 {
            var bytes = [UInt8](repeating: 0, count: 8192)
            var sender = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &sender) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(socketFD, &bytes, bytes.count, 0, $0, &length) } }
            guard count > 0 else { return }
            guard sender.sin_addr.s_addr & interface.mask == inet_addr(interface.address) & interface.mask else { continue }
            let message = String(decoding: bytes.prefix(count), as: UTF8.self)
            let lines = message.components(separatedBy: "\r\n")
            guard lines.first == "M-SEARCH * HTTP/1.1", pending < 40 else { continue }
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                if let colon = line.firstIndex(of: ":") { headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces) }
            }
            guard headers["man"]?.lowercased() == "\"ssdp:discover\"", let search = headers["st"] else { continue }
            let matches = search == "ssdp:all" ? types : types.filter { $0 == search }
            guard !matches.isEmpty else { continue }
            pending += 1
            let token = generation
            let mx = min(max(Int(headers["mx"] ?? "1") ?? 1, 0), 3)
            queue.asyncAfter(deadline: .now() + Double.random(in: 0...Double(mx))) { [weak self] in
                guard let self else { return }
                self.pending -= 1
                guard self.generation == token, self.socketFD >= 0 else { return }
                for type in matches {
                    self.send("HTTP/1.1 200 OK\r\nCACHE-CONTROL: max-age=180\r\nEXT:\r\nLOCATION: \(self.location)\r\nSERVER: Darwin/1.0 UPnP/1.0 Lantern/0.1\r\nST: \(type)\r\nUSN: \(self.usn(type))\r\n\r\n", to: sender)
                }
                self.log("Answered a TV/device discovery request")
            }
        }
    }
}
