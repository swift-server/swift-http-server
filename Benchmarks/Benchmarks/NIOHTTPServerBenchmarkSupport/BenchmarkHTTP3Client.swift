import HTTP3
import HTTPTypes
import Logging
import NIOCore
import NIOEmbedded
import NIOHTTP3
import NIOHTTPTypes
import NIOQUIC
import NIOQUICHelpers

private final class ForwardingDestination: @unchecked Sendable {
    private let synchronizingEventLoop: NIOAsyncTestingEventLoop
    private var current: NIOAsyncTestingChannel?

    init(synchronizingOn eventLoop: NIOAsyncTestingEventLoop) {
        self.synchronizingEventLoop = eventLoop
    }

    func update(to channel: NIOAsyncTestingChannel) async throws {
        try await self.synchronizingEventLoop.executeInContext { self.current = channel }
    }

    func currentChannel() async throws -> NIOAsyncTestingChannel? {
        try await self.synchronizingEventLoop.executeInContext { self.current }
    }
}

public final class BenchmarkHTTP3Client {
    static let port = 9090

    private let channel: NIOAsyncTestingChannel
    private let quicHandler: NIOLoopBound<QUICHandler>
    private let logger: Logger
    private let destination: ForwardingDestination
    private let forwardTask: Task<Void, any Error>

    private init(
        channel: NIOAsyncTestingChannel,
        quicHandler: NIOLoopBound<QUICHandler>,
        logger: Logger,
        destination: ForwardingDestination,
        forwardTask: Task<Void, any Error>
    ) {
        self.channel = channel
        self.quicHandler = quicHandler
        self.logger = logger
        self.destination = destination
        self.forwardTask = forwardTask
    }

    public static func start(
        eventLoop: NIOAsyncTestingEventLoop,
        certificate: BenchmarkCertificate
    ) async throws -> BenchmarkHTTP3Client {
        let channel = NIOAsyncTestingChannel(loop: eventLoop)
        try await connectTestChannel(channel, localPort: Self.port, remotePort: BenchmarkHTTP3Server.port)

        let logger = Logger(label: "NIOHTTPServerBenchmarks.client")
        let quicConfiguration = QUICConfiguration.client(
            verificationConfiguration: .x509Certificates(trustRootsFilePath: certificate.certificatePath),
            applicationProtocols: ["h3"]
        )
        let asyncVerifier = try NIOQUIC.AsyncVerifier(
            trustRootsPath: certificate.certificatePath,
            certificateVerification: .noHostnameVerification,
            eventLoop: channel.eventLoop
        )

        let quicHandler = try await channel.eventLoop.submit {
            let quicHandler = QUICHandler(
                channel: channel,
                quicConfiguration: quicConfiguration,
                asyncVerifier: asyncVerifier,
                authenticator: nil,
                logger: logger,
                inboundConnectionInitializer: { _, _ in fatalError() },
                inboundStreamInitializer: { _ in fatalError() },
                noMoreConnections: {}
            )
            try channel.pipeline.syncOperations.addHandler(quicHandler)
            channel.pipeline.fireChannelActive()
            return NIOLoopBound(quicHandler, eventLoop: channel.eventLoop)
        }.get()

        let destination = ForwardingDestination(synchronizingOn: eventLoop)
        let forwardTask = Task {
            while !Task.isCancelled {
                let datagram = try await channel.waitForOutboundWrite(as: AddressedEnvelope<ByteBuffer>.self)
                if let target = try await destination.currentChannel() {
                    try await target.writeInbound(datagram)
                }
            }
        }

        return BenchmarkHTTP3Client(
            channel: channel,
            quicHandler: quicHandler,
            logger: logger,
            destination: destination,
            forwardTask: forwardTask
        )
    }

    public func attach(to server: BenchmarkHTTP3Server) async throws {
        try await self.destination.update(to: server.channel)

        let clientChannel = self.channel
        let serverChannel = server.channel
        _ = Task {
            while !Task.isCancelled {
                let datagram = try await serverChannel.waitForOutboundWrite(as: AddressedEnvelope<ByteBuffer>.self)
                try await clientChannel.writeInbound(datagram)
            }
        }
    }

    public func openConnection() async throws -> BenchmarkHTTP3Connection {
        let logger = self.logger
        let remoteAddress = self.channel.remoteAddress!
        let quicHandler = self.quicHandler
        let (channel, _) = try await self.channel.eventLoop.flatSubmit {
            quicHandler.value.createOutboundConnection(
                serverName: "127.0.0.1",
                remoteAddress: remoteAddress,
                connectionInitializer: { connectionChannel, streamCreator in
                    connectionChannel.eventLoop.makeCompletedFuture {
                        let h3Handler = HTTP3ConnectionHandler.client(
                            eventLoop: connectionChannel.eventLoop,
                            configuration: .defaults,
                            settings: HTTP3Settings(),
                            streamCreator: streamCreator,
                            logger: logger,
                            inboundPushStreamInitializer: { _ in fatalError() }
                        )
                        try connectionChannel.pipeline.syncOperations.addHandler(h3Handler)
                    }
                },
                inboundStreamInitializer: { streamChannel in
                    streamChannel.parent!.pipeline.handler(
                        type: HTTP3ConnectionHandler<NIOQUIC.QUICStreamCreator>.self
                    )
                    .flatMap { $0.inboundStreamReceived(streamChannel) }
                }
            )
        }.get()

        return BenchmarkHTTP3Connection(channel: channel)
    }

    public func shutdown() async throws {
        self.forwardTask.cancel()
        try await self.channel.close()
    }
}
