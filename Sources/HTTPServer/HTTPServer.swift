public import HTTPTypes
public import Logging
import NIOCore
import NIOHTTP1
import NIOHTTP2
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import X509
import SwiftASN1

/// A generic HTTP server that can handle incoming HTTP requests.
///
/// The `Server` class provides a high-level interface for creating HTTP servers with support for:
/// - TLS/SSL encryption
/// - Custom request handlers
/// - Configurable binding targets
/// - Async/await request processing
/// - Bi-directional streaming support
/// - Request and response trailers
///
/// ## Usage
///
/// ```swift
/// let configuration = HTTPServerConfiguration(
///     bindTarget: .hostAndPort(host: "localhost", port: 8080),
///     tlsConfiguration: .insecure()
/// )
///
/// try await Server.serve(
///     logger: logger,
///     configuration: configuration
/// ) { request, bodyReader, sendResponse in
///     // Read the entire request body
///     let (bodyData, trailers) = try await bodyReader.consumeAndConclude { reader in
///         var data = [UInt8]()
///         var shouldContinue = true
///         while shouldContinue {
///             try await reader.read { span in
///                 guard let span else {
///                     shouldContinue = false
///                     return
///                 }
///                 data.append(contentsOf: span)
///             }
///         }
///         return data
///     }
///
///     // Create and send response
///     var response = HTTPResponse(status: .ok)
///     response.headerFields[.contentType] = "text/plain"
///     let responseWriter = try await sendResponse(response)
///     try await responseWriter.produceAndConclude { writer in
///         try await writer.write("Hello, World!".utf8CString.dropLast().span)
///         return ((), nil)
///     }
/// }
/// ```
public final class Server<RequestHandler: HTTPServerRequestHandler> {
    /// Starts an HTTP server with a closure-based request handler.
    ///
    /// This method provides a convenient way to start an HTTP server using a closure to handle incoming requests.
    /// The server will bind to the specified configuration and process requests asynchronously.
    ///
    /// - Parameters:
    ///   - logger: A logger instance for recording server events and debugging information.
    ///   - configuration: The server configuration including bind target and TLS settings.
    ///   - handler: An async closure that processes HTTP requests. The closure receives:
    ///     - `HTTPRequest`: The incoming HTTP request with headers and metadata
    ///     - `HTTPRequestConcludingAsyncReader`: An async reader for consuming the request body and trailers
    ///     - A response sender function that accepts an `HTTPResponse` and provides access to an `HTTPResponseConcludingAsyncWriter`
    ///
    /// ## Example
    ///
    /// ```swift
    /// let configuration = HTTPServerConfiguration(
    ///     bindTarget: .hostAndPort(host: "localhost", port: 8080),
    ///     tlsConfiguration: .insecure()
    /// )
    ///
    /// try await Server.serve(
    ///     logger: logger,
    ///     configuration: configuration
    /// ) { request, bodyReader, sendResponse in
    ///     // Process the request
    ///     let response = HTTPResponse(status: .ok)
    ///     let writer = try await sendResponse(response)
    ///     try await writer.produceAndConclude { writer in
    ///         try await writer.write("Hello, World!".utf8)
    ///         return ((), nil)
    ///     }
    /// }
    /// ```
    public static func serve(
        logger: Logger,
        configuration: HTTPServerConfiguration,
        handler: @escaping @Sendable (
            HTTPRequest,
            HTTPRequestConcludingAsyncReader,
            @escaping (
                HTTPResponse
            ) async throws -> HTTPResponseConcludingAsyncWriter
        ) async throws -> Void
    ) async throws where RequestHandler == HTTPServerClosureRequestHandler {
        try await self.serve(
            logger: logger,
            configuration: configuration,
            handler: HTTPServerClosureRequestHandler(handler: handler)
        )
    }

    /// Starts an HTTP server with the specified request handler.
    ///
    /// This method creates and runs an HTTP server that processes incoming requests using the provided
    /// ``HTTPServerRequestHandler`` implementation. The server binds to the specified configuration and
    /// handles each connection concurrently using Swift's structured concurrency.
    ///
    /// - Parameters:
    ///   - logger: A logger instance for recording server events and debugging information.
    ///   - configuration: The server configuration including bind target and TLS settings.
    ///   - handler: A ``HTTPServerRequestHandler`` implementation that processes incoming HTTP requests. The handler
    ///     receives each request along with a body reader and response sender function.
    ///
    /// ## Example
    ///
    /// ```swift
    /// struct EchoHandler: HTTPServerRequestHandler {
    ///     func handle(
    ///         request: HTTPRequest,
    ///         requestConcludingAsyncReader: HTTPRequestConcludingAsyncReader,
    ///         sendResponse: @escaping (HTTPResponse) async throws -> HTTPResponseConcludingAsyncWriter
    ///     ) async throws {
    ///         let response = HTTPResponse(status: .ok)
    ///         let writer = try await sendResponse(response)
    ///         // Handle request and write response...
    ///     }
    /// }
    ///
    /// let configuration = HTTPServerConfiguration(
    ///     bindTarget: .hostAndPort(host: "localhost", port: 8080),
    ///     tlsConfiguration: .insecure()
    /// )
    ///
    /// try await Server.serve(
    ///     logger: logger,
    ///     configuration: configuration,
    ///     handler: EchoHandler()
    /// )
    /// ```
    public static func serve(
        logger: Logger,
        configuration: HTTPServerConfiguration,
        handler: RequestHandler
    ) async throws {
        let serverChannel = try await Self.bind(
            bindTarget: configuration.bindTarget
        ) {
            (
                channel
            ) -> EventLoopFuture<
                EventLoopFuture<
                    NIONegotiatedHTTPVersion<
                        NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
                        (
                            Void,
                            NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>
                        )
                    >
                >
            > in
            channel.eventLoop.makeCompletedFuture {
                switch configuration.tlSConfiguration.backing {
                case .insecure:
                    break
                case .certificateChainAndPrivateKey(
                    let certificateChain,
                    let privateKey
                ):
                    let certificateChain =
                        try certificateChain
                        .map {
                            try NIOSSLCertificate(
                                bytes: $0.serializeAsPEM().derBytes,
                                format: .der
                            )
                        }
                        .map { NIOSSLCertificateSource.certificate($0) }
                    let privateKey = NIOSSLPrivateKeySource.privateKey(
                        try NIOSSLPrivateKey(
                            bytes: privateKey.serializeAsPEM().derBytes,
                            format: .der
                        )
                    )

                    try channel.pipeline.syncOperations
                        .addHandler(
                            NIOSSLServerHandler(
                                context: .init(
                                    configuration:
                                        .makeServerConfiguration(
                                            certificateChain: certificateChain,
                                            privateKey: privateKey
                                        )
                                )
                            )
                        )
                }
            }.flatMap {
                channel
                    .configureAsyncHTTPServerPipeline { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))

                            return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                wrappingChannelSynchronously: channel,
                                configuration: .init(isOutboundHalfClosureEnabled: true)
                            )
                        }
                    } http2ConnectionInitializer: { channel in
                        channel.eventLoop.makeSucceededVoidFuture()
                    } http2StreamInitializer: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations
                                .addHandler(
                                    HTTP2FramePayloadToHTTPServerCodec()
                                )

                            return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                wrappingChannelSynchronously: channel,
                                configuration: .init(isOutboundHalfClosureEnabled: true)
                            )
                        }
                    }
            }
        }

        try await withThrowingDiscardingTaskGroup { group in
            try await serverChannel.executeThenClose { inbound in
                for try await upgradeResult in inbound {
                    group.addTask {
                        do {
                            try await withThrowingDiscardingTaskGroup { connectionGroup in
                                switch try await upgradeResult.get() {
                                case .http1_1(let http1Channel):
                                    connectionGroup.addTask {
                                        await Self.handleRequestChannel(
                                            logger: logger,
                                            channel: http1Channel,
                                            handler: handler
                                        )
                                    }
                                case .http2((_, let http2Multiplexer)):
                                    do {
                                        for try await http2StreamChannel in http2Multiplexer.inbound {
                                            connectionGroup.addTask {
                                                await Self.handleRequestChannel(
                                                    logger: logger,
                                                    channel: http2StreamChannel,
                                                    handler: handler
                                                )
                                            }
                                        }
                                    } catch {
                                        logger.debug("HTTP2 connection closed")
                                    }
                                }
                            }
                        } catch {
                            logger.debug("Negotiating ALPN failed")
                        }
                    }
                }
            }
        }
    }

    private static func handleRequestChannel(
        logger: Logger,
        channel: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
        handler: RequestHandler
    ) async {
        do {
            try await channel
                .executeThenClose { inbound, outbound in
                    var iterator = inbound.makeAsyncIterator()

                    let httpRequest: HTTPRequest
                    switch try await iterator.next() {
                    case .head(let request):
                        httpRequest = request
                    case .body:
                        logger.debug("Unexpectedly received body on connection. Closing now")
                        outbound.finish()
                        return
                    case .end:
                        logger.debug("Unexpectedly received end on connection. Closing now")
                        outbound.finish()
                        return
                    case .none:
                        logger.trace("No more requests parts on connection")
                        return
                    }

                    try await handler.handle(
                        request: httpRequest,
                        requestConcludingAsyncReader: HTTPRequestConcludingAsyncReader(
                            iterator: iterator
                        ),
                        sendResponse: { response in
                            try await outbound.write(.head(response))
                            return HTTPResponseConcludingAsyncWriter(writer: outbound)
                        }
                    )
                    // TODO: We need to send a response head here potentially
                }
        } catch {
            logger.debug("Error thrown while handling connection")
            // TODO: We need to send a response head here potentially
        }
    }

    private static func bind(
        bindTarget: HTTPServerConfiguration.BindTarget,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<
            EventLoopFuture<
                NIONegotiatedHTTPVersion<
                    NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
                    (Void, NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>)
                >
            >
        >
    ) async throws -> NIOAsyncChannel<
        EventLoopFuture<
            NIONegotiatedHTTPVersion<
                NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>,
                (Void, NIOHTTP2Handler.AsyncStreamMultiplexer<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>>)
            >
        >, Never
    > {
        switch bindTarget.backing {
        case .hostAndPort(let host, let port):
            return try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(
                    host: host,
                    port: port,
                    childChannelInitializer: childChannelInitializer
                )
        }

    }
}
