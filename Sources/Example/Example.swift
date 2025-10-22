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
        try await Server.serve(
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
            ), handler: handler(request:requestConcludingAsyncReader:responseSender:))
    }

    // This is a workaround for a current bug with the compiler.
    @Sendable
    nonisolated(nonsending) private static func handler(
        request: HTTPRequest,
        requestConcludingAsyncReader: consuming HTTPRequestConcludingAsyncReader,
        responseSender: consuming HTTPResponseSender<HTTPResponseConcludingAsyncWriter>
    ) async throws {
        let writer = try await responseSender.sendResponse(HTTPResponse(status: .ok))
        try await writer.writeAndConclude(element: "Well, hello!".utf8.span, finalElement: nil)
    }
}

// MARK: - Server Extensions

// This has to be commented out because of the compiler bug above. Workaround doesn't apply here.

//@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
//extension Server {
//    /// Serve HTTP requests using a middleware chain built with the provided builder
//    /// This method handles the type inference for HTTP middleware components
//    static func serve(
//        logger: Logger,
//        configuration: HTTPServerConfiguration,
//        @MiddlewareChainBuilder
//        withMiddleware middlewareBuilder: () -> some Middleware<
//            RequestResponseContext<
//                HTTPRequestConcludingAsyncReader,
//                HTTPResponseConcludingAsyncWriter
//            >,
//            Never
//        > & Sendable
//    ) async throws where RequestHandler == HTTPServerClosureRequestHandler {
//        let chain = middlewareBuilder()
//
//        try await serve(
//            logger: logger,
//            configuration: configuration
//        ) { request, reader, responseSender in
//            try await chain.intercept(input: RequestResponseContext(
//                request: request,
//                requestReader: reader,
//                responseSender: responseSender
//            )) { _ in }
//        }
//    }
//}
