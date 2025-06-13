import Crypto
import Foundation
import HTTPServer
import HTTPTypes
import Instrumentation
import Logging
import Middleware
import X509

@main
struct Example {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        InstrumentationSystem.bootstrap(LogTracer())
        let logger = Logger(label: "Logger")

        // Using the new extension method that doesn't require type hints
        let privateKey = P256.Signing.PrivateKey()
        try await Server.serve(
            logger: logger,
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                tlsConfiguration: .certificateChainAndPrivateKey(
                    certificateChain: [
                        try Certificate(
                            version: .v3,
                            serialNumber: .init(bytes: [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]),
                            publicKey: .init(privateKey.publicKey),
                            notValidBefore: Date.now.addingTimeInterval(-60),
                            notValidAfter: Date.now.addingTimeInterval(60 * 60),
                            issuer: DistinguishedName(),
                            subject: DistinguishedName(),
                            signatureAlgorithm: .ecdsaWithSHA256,
                            extensions: .init(),
                            issuerPrivateKey: Certificate.PrivateKey(privateKey)
                        )
                    ],
                    privateKey: Certificate.PrivateKey(privateKey)
                )
            ),
            withMiddleware: {
                HTTPRequestLoggingMiddleware<
                    HTTPRequestConcludingAsyncReader,
                    HTTPResponseConcludingAsyncWriter
                >(logger: logger)
                TracingMiddleware<
                    (
                        HTTPRequest,
                        HTTPRequestLoggingConcludingAsyncReader<HTTPRequestConcludingAsyncReader>,
                        (
                            HTTPResponse
                        ) async throws -> HTTPResponseLoggingConcludingAsyncWriter<HTTPResponseConcludingAsyncWriter>
                    )
                >()
                RouteHandlerMiddleware<
                    HTTPRequestLoggingConcludingAsyncReader<HTTPRequestConcludingAsyncReader>,
                    HTTPResponseLoggingConcludingAsyncWriter<HTTPResponseConcludingAsyncWriter>
                >()
            }
        )
    }
}

// MARK: - Server Extensions

extension Server {
    /// Serve HTTP requests using a middleware chain built with the provided builder
    /// This method handles the type inference for HTTP middleware components
    static func serve(
        logger: Logger,
        configuration: HTTPServerConfiguration,
        @MiddlewareChainBuilder
        withMiddleware middlewareBuilder: () -> some Middleware<
            (
                HTTPRequest,
                HTTPRequestConcludingAsyncReader,
                (
                    HTTPResponse
                ) async throws -> HTTPResponseConcludingAsyncWriter
            ),
            Never
        > & Sendable
    ) async throws where RequestHandler == HTTPServerClosureRequestHandler {
        let chain = middlewareBuilder()

        try await serve(
            logger: logger,
            configuration: configuration
        ) { request, requestReader, sendResponse in
            try await chain.intercept(input: (request, requestReader, sendResponse)) { _ in }
        }
    }
}
