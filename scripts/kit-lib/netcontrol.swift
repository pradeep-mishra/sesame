// netcontrol.swift: the planted short connection of the S8.7 network checks (verify.md, Kit scripts: kit-net.sh control;
// guesses K25 and K26). Compiled by `kit-net.sh control` to $KIT_ROOT/apps/SesameNetControl, so the name prefix `Sesame`
// that both observers (nettop and the fs_usage network trace) scope on covers it exactly as it covers the product.
// Foundation and Darwin only. It talks to itself on 127.0.0.1 and never to anything else.
//
//   SesameNetControl --name <name> --n <k> [--avoid <port>]
//     Opens a listener on 127.0.0.1 on a free port the system picks (port 0; never the port after --avoid, which is the
//     mirror's), connects to it, sends 64 bytes, holds the connection for 20 ms, closes it, and prints one line:
//       PLANT <name> n=<k> pid=<pid> at=<epoch.ms> addr=127.0.0.1:<port>
//     `at` is the moment of the connect. The line is the only output; every failure is one line on stderr and exit 1.
import Foundation
import Darwin

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data(("SesameNetControl: " + message + "\n").utf8))
    exit(1)
}

// ---- arguments -----------------------------------------------------------------------------------

var plantName = ""
var plantNumber = 0
var avoidPort: UInt16 = 0
do {
    let a = CommandLine.arguments
    var i = 1
    while i < a.count {
        guard i + 1 < a.count else { fail("missing value after \(a[i])") }
        switch a[i] {
        case "--name": plantName = a[i + 1]
        case "--n": plantNumber = Int(a[i + 1]) ?? 0
        case "--avoid": avoidPort = UInt16(a[i + 1]) ?? 0
        default: fail("unknown option \(a[i])")
        }
        i += 2
    }
}
if plantName.isEmpty || plantNumber < 1 { fail("usage: SesameNetControl --name <name> --n <k> [--avoid <port>]") }

signal(SIGPIPE, SIG_IGN)

// ---- the listener --------------------------------------------------------------------------------

func loopback(port: UInt16) -> sockaddr_in {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    return addr
}

/// A listening socket on 127.0.0.1 and the port it got. Port 0 asks the system for a free one; a port that equals
/// --avoid is given back and another is asked for.
func makeListener() -> (fd: Int32, port: UInt16) {
    for _ in 0..<20 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        if fd < 0 { fail("socket failed (errno \(errno))") }
        var addr = loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if bound != 0 { fail("bind failed (errno \(errno))") }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        if named != 0 { fail("getsockname failed (errno \(errno))") }
        let port = UInt16(bigEndian: addr.sin_port)
        if port == avoidPort || port == 0 {
            close(fd)
            continue
        }
        if listen(fd, 1) != 0 { fail("listen failed (errno \(errno))") }
        return (fd, port)
    }
    fail("no free port other than \(avoidPort) after 20 tries")
}

let listener = makeListener()

// ---- the connection ------------------------------------------------------------------------------

let client = socket(AF_INET, SOCK_STREAM, 0)
if client < 0 { fail("socket failed (errno \(errno))") }
var target = loopback(port: listener.port)
let connected = withUnsafePointer(to: &target) {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
}
if connected != 0 { fail("connect failed (errno \(errno))") }
let connectedAt = Date().timeIntervalSince1970

let accepted = accept(listener.fd, nil, nil)
if accepted < 0 { fail("accept failed (errno \(errno))") }

let payload = [UInt8](repeating: 0x2e, count: 64)
let sent = payload.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }
if sent != 64 { fail("sent \(sent) bytes, not 64") }

usleep(20_000)
close(client)
close(accepted)
close(listener.fd)

print("PLANT \(plantName) n=\(plantNumber) pid=\(getpid()) at=\(String(format: "%.3f", connectedAt)) addr=127.0.0.1:\(listener.port)")
