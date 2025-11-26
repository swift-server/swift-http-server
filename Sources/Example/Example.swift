import Crypto
import Foundation
import HTTPServer
import HTTPTypes
import Instrumentation
import Logging
import Middleware
import X509

@main
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct Example {
    static func main() async throws {
        try await serve()
    }

    @concurrent
    static func serve() async throws {
        InstrumentationSystem.bootstrap(LogTracer())
        var logger = Logger(label: "Logger")
        logger.logLevel = .trace

        // Using the new extension method that doesn't require type hints
        let privateKey = P256.Signing.PrivateKey()
        let server = NIOHTTPServer(
            logger: logger,
            configuration: .init(
                bindTarget: .hostAndPort(host: "127.0.0.1", port: 12345),
                transportSecurity: .tls(
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
            )
        )

        try await server.serve { request, requestContext, requestBodyAndTrailers, responseSender in
            let writer = try await responseSender.send(HTTPResponse(status: .ok))
            try await writer.writeAndConclude(element: "Well, hello!".utf8.span, finalElement: nil)
        }
    }
}

// MARK: - Server Extensions

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOHTTPServer {
    /// Serve HTTP requests using a middleware chain built with the provided builder
    /// This method handles the type inference for HTTP middleware components
    func serve(
        @MiddlewareChainBuilder
        withMiddleware middlewareBuilder: () -> some Middleware<
            RequestResponseMiddlewareBox<
                HTTPRequestConcludingAsyncReader,
                HTTPResponseConcludingAsyncWriter
            >,
            Never
        > & Sendable
    ) async throws {
        let chain = middlewareBuilder()

        try await self.serve { request, requestContext, reader, responseSender in
            try await chain.intercept(input: RequestResponseMiddlewareBox(
                request: request,
                requestContext: requestContext,
                requestReader: reader,
                responseSender: responseSender
            )) { _ in }
        }
    }
}
