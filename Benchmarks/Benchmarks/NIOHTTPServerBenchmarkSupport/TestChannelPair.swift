import NIOCore
import NIOEmbedded

func connectTestChannel(_ channel: NIOAsyncTestingChannel, localPort: Int, remotePort: Int) async throws {
    try await channel.testingEventLoop.executeInContext {
        channel.localAddress = try SocketAddress(ipAddress: "127.0.0.1", port: localPort)
        channel.remoteAddress = try SocketAddress(ipAddress: "127.0.0.1", port: remotePort)
    }
    try await channel.connect(to: channel.remoteAddress!)
}
