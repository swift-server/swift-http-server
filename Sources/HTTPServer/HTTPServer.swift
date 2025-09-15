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
import Synchronization

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
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
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
    ///     - A non-copyable response sender function that accepts an `HTTPResponse` and provides access to an `HTTPResponseConcludingAsyncWriter`
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
        handler: @Sendable @escaping (
            HTTPRequest,
            consuming HTTPRequestConcludingAsyncReader,
            consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
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
        let asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration
        switch configuration.backpressureStrategy.backing {
        case .watermark(let low, let high):
            asyncChannelConfiguration = .init(
                backPressureStrategy: .init(lowWatermark: low, highWatermark: high),
                isOutboundHalfClosureEnabled: true
            )
        }

        switch configuration.tlSConfiguration.backing {
        case .insecure:
            try await Self.serveInsecureHTTP1_1(
                bindTarget: configuration.bindTarget,
                handler: handler,
                asyncChannelConfiguration: asyncChannelConfiguration,
                logger: logger
            )

        case .certificateChainAndPrivateKey(let certificateChain, let privateKey):
            try await Self.serveSecureUpgrade(
                bindTarget: configuration.bindTarget,
                certificateChain: certificateChain,
                privateKey: privateKey,
                handler: handler,
                asyncChannelConfiguration: asyncChannelConfiguration,
                logger: logger
            )
        }
    }

    private static func serveInsecureHTTP1_1(
        bindTarget: HTTPServerConfiguration.BindTarget,
        handler: RequestHandler,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        logger: Logger
    ) async throws {
        switch bindTarget.backing {
        case .hostAndPort(let host, let port):
            let serverChannel = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: port) { channel in
                    channel.pipeline.configureHTTPServerPipeline().flatMapThrowing {
                        try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: false))
                        return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                            wrappingChannelSynchronously: channel,
                            configuration: asyncChannelConfiguration
                        )
                    }
                }

            try await withThrowingDiscardingTaskGroup { group in
                try await serverChannel.executeThenClose { inbound in
                    for try await http1Channel in inbound {
                        group.addTask {
                            await Self.handleRequestChannel(
                                logger: logger,
                                channel: http1Channel,
                                handler: handler
                            )
                        }
                    }
                }
            }
        }
    }

    private static func serveSecureUpgrade(
        bindTarget: HTTPServerConfiguration.BindTarget,
        certificateChain: [Certificate],
        privateKey: Certificate.PrivateKey,
        handler: RequestHandler,
        asyncChannelConfiguration: NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>.Configuration,
        logger: Logger
    ) async throws {
        switch bindTarget.backing {
        case .hostAndPort(let host, let port):
            let serverChannel = try await ServerBootstrap(group: .singletonMultiThreadedEventLoopGroup)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .bind(host: host, port: port) { channel in
                    channel.eventLoop.makeCompletedFuture {
                        let certificateChain = try certificateChain
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

                        var tlsConfiguration: TLSConfiguration = .makeServerConfiguration(
                            certificateChain: certificateChain,
                            privateKey: privateKey
                        )
                        tlsConfiguration.applicationProtocols = ["h2", "http/1.1"]

                        try channel.pipeline.syncOperations
                            .addHandler(
                                NIOSSLServerHandler(
                                    context: .init(configuration: tlsConfiguration)
                                )
                            )
                    }.flatMap {
                        channel.configureAsyncHTTPServerPipeline { channel in
                            channel.eventLoop.makeCompletedFuture {
                                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPServerCodec(secure: true))

                                return try NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>(
                                    wrappingChannelSynchronously: channel,
                                    configuration: asyncChannelConfiguration
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
                                    configuration: asyncChannelConfiguration
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
                                            logger.debug("HTTP2 connection closed: \(error)")
                                        }
                                    }
                                }
                            } catch {
                                logger.debug("Negotiating ALPN failed: \(error)")
                            }
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

                    let readerState = HTTPRequestConcludingAsyncReader.ReaderState()
                    let writerState = HTTPResponseConcludingAsyncWriter.WriterState()

                    do {
                        try await handler.handle(
                            request: httpRequest,
                            requestConcludingAsyncReader: HTTPRequestConcludingAsyncReader(
                                iterator: iterator,
                                readerState: readerState
                            ),
                            sendResponse: HTTPResponseSender { response in
                                try await outbound.write(.head(response))
                                return HTTPResponseConcludingAsyncWriter(
                                    writer: outbound,
                                    writerState: writerState
                                )
                            }
                        )
                    } catch {
                        if !readerState.wrapped.withLock({ $0.finishedReading }) {
                            // TODO: do something - we didn't finish reading but we threw
                            // if h2 reset stream; if h1 try draining request?
                            fatalError("Didn't finish reading but threw.")
                        }
                        if !writerState.wrapped.withLock({ $0.finishedWriting }) {
                            // TODO: this means we didn't write a response end and we threw
                            // we need to do something, possibly just close the connection or
                            // reset the stream with the appropriate error.
                            fatalError("Didn't finish writing but threw.")
                        }
                    }

                    // TODO: handle other state scenarios.
                    // For example, if we're using h2 and we didn't finish reading but we wrote back
                    // a response, we should send a RST_STREAM with NO_ERROR set.
                    // If we finished reading but we didn't write back a response, then RST_STREAM
                    // is also likely appropriate but unclear about the error.
                    // For h1, we should close the connection.
                }
        } catch {
            logger.debug("Error thrown while handling connection: \(error)")
            // TODO: We need to send a response head here potentially
        }
    }
}
