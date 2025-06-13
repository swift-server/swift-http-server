import HTTPServer
import HTTPTypes
import Logging
import Middleware

struct HTTPRequestLoggingMiddleware<
    RequestConludingAsyncReader: ConcludingAsyncReader,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable
>: Middleware
where
    RequestConludingAsyncReader.Underlying: AsyncReader<Span<UInt8>, any Error>,
    RequestConludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying: AsyncWriter<Span<UInt8>, any Error>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    typealias Input = (
        HTTPRequest, RequestConludingAsyncReader, (HTTPResponse) async throws -> ResponseConcludingAsyncWriter
    )
    typealias NextInput = (
        HTTPRequest,
        HTTPRequestLoggingConcludingAsyncReader<RequestConludingAsyncReader>,
        (
            HTTPResponse
        ) async throws -> HTTPResponseLoggingConcludingAsyncWriter<ResponseConcludingAsyncWriter>
    )

    let logger: Logger

    init(
        requestConludingAsyncReaderType: RequestConludingAsyncReader.Type = RequestConludingAsyncReader.self,
        responseConcludingAsyncWriterType: ResponseConcludingAsyncWriter.Type = ResponseConcludingAsyncWriter.self,
        logger: Logger
    ) {
        self.logger = logger
    }

    func intercept(
        input: Input,
        next: (NextInput) async throws -> Void
    ) async throws {
        let request = input.0
        let requestAsyncReader = input.1
        let respond = input.2
        self.logger.info("Received request \(request.path ?? "unknown" ) \(request.method.rawValue)")
        defer {
            self.logger.info("Finished request \(request.path ?? "unknown" ) \(request.method.rawValue)")
        }
        let wrappedReader = HTTPRequestLoggingConcludingAsyncReader(
            base: requestAsyncReader,
            logger: self.logger
        )
        try await next(
            (
                request, wrappedReader,
                { httpResponse in
                    let writer = try await respond(httpResponse)
                    return HTTPResponseLoggingConcludingAsyncWriter(
                        base: writer,
                        logger: self.logger
                    )
                }
            )
        )
    }
}

struct HTTPRequestLoggingConcludingAsyncReader<
    Base: ConcludingAsyncReader
>: ConcludingAsyncReader
where
    Base.Underlying: AsyncReader<Span<UInt8>, any Error>,
    Base.FinalElement == HTTPFields?
{
    typealias Underlying = RequestBodyAsyncReader
    typealias FinalElement = HTTPFields?

    struct RequestBodyAsyncReader: AsyncReader {
        typealias ReadElement = Span<UInt8>
        typealias ReadFailure = any Error

        private var underlying: Base.Underlying
        private let logger: Logger

        init(underlying: Base.Underlying, logger: Logger) {
            self.underlying = underlying
            self.logger = logger
        }

        mutating func read<Return>(
            body: (consuming Span<UInt8>?) async throws -> Return
        ) async throws(any Error) -> Return {
            let logger = self.logger
            return try await self.underlying.read { span in
                logger.info("Received next chunk \(span?.count ?? 0)")
                return try await body(span)
            }
        }
    }

    private var base: Base
    private let logger: Logger

    init(base: Base, logger: Logger) {
        self.base = base
        self.logger = logger
    }

    func consumeAndConclude<Return>(
        body: (inout RequestBodyAsyncReader) async throws -> Return
    ) async throws -> (Return, HTTPFields?) {
        let (result, trailers) = try await self.base.consumeAndConclude { bodyAsyncReader in
            var wrappedReader = RequestBodyAsyncReader(
                underlying: bodyAsyncReader,
                logger: self.logger
            )
            return try await body(&wrappedReader)
        }

        if let trailers {
            self.logger.info("Received request trailers \(trailers)")
        } else {
            self.logger.info("Received no request trailers")
        }
        return (result, trailers)
    }
}

struct HTTPResponseLoggingConcludingAsyncWriter<
    Base: ConcludingAsyncWriter & ~Copyable
>: ConcludingAsyncWriter, ~Copyable
where
    Base.Underlying: AsyncWriter<Span<UInt8>, any Error>,
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
