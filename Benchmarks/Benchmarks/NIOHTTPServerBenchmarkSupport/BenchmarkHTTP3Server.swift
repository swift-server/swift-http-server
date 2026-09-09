import BasicContainers
import HTTPTypes
import Logging
import NIOCore
public import NIOEmbedded
@_spi(Benchmarks) import NIOHTTPServer

let benchmarkPayloadSize = 1024
let serverPort = 8080
let clientPort = 9090

public final class BenchmarkHTTP3Server {
    static let port = 8080

    let channel: NIOAsyncTestingChannel
    private let serveTask: Task<Void, any Error>

    private init(channel: NIOAsyncTestingChannel, serveTask: Task<Void, any Error>) {
        self.channel = channel
        self.serveTask = serveTask
    }

    public static func start(
        eventLoop: NIOAsyncTestingEventLoop,
        certificate: BenchmarkCertificate
    ) async throws -> BenchmarkHTTP3Server {
        let channel = NIOAsyncTestingChannel(loop: eventLoop)
        try await connectTestChannel(channel, localPort: Self.port, remotePort: BenchmarkHTTP3Client.port)

        let configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http3],
            transportSecurity: certificate.transportSecurity
        )
        let server = NIOHTTPServer(
            logger: Logger(label: "NIOHTTPServerBenchmarks.server"),
            configuration: configuration
        )

        let serveTask = Task {
            try await server.serveHTTP3OverTestChannel(
                channel: channel,
                handler: HTTPServerClosureRequestHandler { request, requestContext, reader, responseSender in
                    var discard = UniqueArray<UInt8>()
                    _ = try await reader.collect(into: &discard)

                    var body = UniqueArray<UInt8>(repeating: 0, count: benchmarkPayloadSize)
                    try await responseSender.sendAndFinish(HTTPResponse(status: .ok), buffer: &body)
                }
            )
        }

        return BenchmarkHTTP3Server(channel: channel, serveTask: serveTask)
    }

    public func shutdown() async throws {
        self.serveTask.cancel()
        try await self.channel.close()
    }
}
