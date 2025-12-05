@testable import HTTPServer

extension HTTPServer.SocketAddress {
    var host: String {
        switch self.base {
        case .ipv4(let ipv4):
            return ipv4.host
        case .ipv6(let ipv6):
            return ipv6.host
        }
    }

    var port: Int {
        switch self.base {
        case .ipv4(let ipv4):
            return ipv4.port
        case .ipv6(let ipv6):
            return ipv6.port
        }
    }
}
