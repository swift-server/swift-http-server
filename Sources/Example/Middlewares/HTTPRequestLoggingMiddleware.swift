import HTTPServer
import HTTPTypes
import Logging
import Middleware

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HTTPRequestLoggingMiddleware<
    RequestConcludingAsyncReader: ConcludingAsyncReader & ~Copyable,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable
>: Middleware
where
    RequestConcludingAsyncReader.Underlying.ReadElement == Span<UInt8>,
    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying.WriteElement == Span<UInt8>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    typealias Input = RequestResponseMiddlewareBox<RequestConcludingAsyncReader, ResponseConcludingAsyncWriter>
    typealias NextInput = RequestResponseMiddlewareBox<
        HTTPRequestLoggingConcludingAsyncReader<RequestConcludingAsyncReader>,
        HTTPResponseLoggingConcludingAsyncWriter<ResponseConcludingAsyncWriter>
    >

    let logger: Logger

    init(
        requestConcludingAsyncReaderType: RequestConcludingAsyncReader.Type = RequestConcludingAsyncReader.self,
        responseConcludingAsyncWriterType: ResponseConcludingAsyncWriter.Type = ResponseConcludingAsyncWriter.self,
        logger: Logger
    ) {
        self.logger = logger
    }

    func intercept(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Void
    ) async throws {
        try await input.withContents { request, requestReader, responseSender in
            self.logger.info("Received request \(request.path ?? "unknown" ) \(request.method.rawValue)")
            defer {
                self.logger.info("Finished request \(request.path ?? "unknown" ) \(request.method.rawValue)")
            }
            let wrappedReader = HTTPRequestLoggingConcludingAsyncReader(
                base: requestReader,
                logger: self.logger
            )

            var maybeSender = Optional(responseSender)
            let requestResponseBox = RequestResponseMiddlewareBox(
                request: request,
                requestReader: wrappedReader,
                responseSender: HTTPResponseSender { [logger] response in
                    if let sender = maybeSender.take() {
                        let writer = try await sender.sendResponse(response)
                        return HTTPResponseLoggingConcludingAsyncWriter(
                            base: writer,
                            logger: logger
                        )
                    } else {
                        fatalError("Called closure more than once")
                    }
                }
            )
            try await next(requestResponseBox)
        }
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HTTPRequestLoggingConcludingAsyncReader<
    Base: ConcludingAsyncReader & ~Copyable
>: ConcludingAsyncReader, ~Copyable
where
    Base.Underlying.ReadElement == Span<UInt8>,
    Base.FinalElement == HTTPFields?
{
    typealias Underlying = RequestBodyAsyncReader
    typealias FinalElement = HTTPFields?

    struct RequestBodyAsyncReader: AsyncReader, ~Copyable {
        typealias ReadElement = Span<UInt8>
        typealias ReadFailure = any Error

        private var underlying: Base.Underlying
        private let logger: Logger

        init(underlying: consuming Base.Underlying, logger: Logger) {
            self.underlying = underlying
            self.logger = logger
        }

        mutating func read<Return>(
            body: (consuming Span<UInt8>?) async throws -> Return
        ) async throws -> Return {
            let logger = self.logger
            return try await self.underlying.read { span in
                logger.info("Received next chunk \(span?.count ?? 0)")
                return try await body(span)
            }
        }
    }

    private var base: Base
    private let logger: Logger

    init(base: consuming Base, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    consuming func consumeAndConclude<Return>(
        body: (consuming Underlying) async throws -> Return
    ) async throws -> (Return, FinalElement) {
        let (result, trailers) = try await self.base.consumeAndConclude { [logger] reader in
            let wrappedReader = RequestBodyAsyncReader(
                underlying: reader,
                logger: logger
            )
            return try await body(wrappedReader)
        }

        if let trailers {
            self.logger.info("Received request trailers \(trailers)")
        } else {
            self.logger.info("Received no request trailers")
        }

        return (result, trailers)
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
struct HTTPResponseLoggingConcludingAsyncWriter<
    Base: ConcludingAsyncWriter & ~Copyable
>: ConcludingAsyncWriter, ~Copyable
where
    Base.Underlying.WriteElement == Span<UInt8>,
    Base.FinalElement == HTTPFields?
{
    typealias Underlying = ResponseBodyAsyncWriter
    typealias FinalElement = HTTPFields?

    struct ResponseBodyAsyncWriter: AsyncWriter, ~Copyable {
        typealias WriteElement = Span<UInt8>
        typealias WriteFailure = any Error

        private var underlying: Base.Underlying
        private let logger: Logger

        init(underlying: consuming Base.Underlying, logger: Logger) {
            self.underlying = underlying
            self.logger = logger
        }

        mutating func write(_ elements: consuming Span<UInt8>) async throws(any Error) {
            logger.info("Wrote next chunk \(elements.count)")
            try await self.underlying.write(elements)
        }
    }

    private var base: Base
    private let logger: Logger

    init(base: consuming Base, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    consuming func produceAndConclude<Return>(
        body: (consuming ResponseBodyAsyncWriter) async throws -> (Return, HTTPFields?)
    ) async throws -> Return {
        let logger = self.logger
        return try await self.base.produceAndConclude { writer in
            let wrappedAsyncWriter = ResponseBodyAsyncWriter(underlying: writer, logger: logger)
            let (result, trailers) = try await body(wrappedAsyncWriter)

            if let trailers {
                logger.info("Wrote response trailers \(trailers)")
            } else {
                logger.info("Wrote no response trailers")
            }
            return (result, trailers)
        }
    }
}
