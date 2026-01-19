//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

// This is currently commented out because a compiler bug is causing issues.

//import HTTPServer
//import HTTPTypes
//import Logging
//import Middleware
//import AsyncStreaming
//import BasicContainers
//
//@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
//struct HTTPRequestLoggingMiddleware<
//    RequestConcludingAsyncReader: ConcludingAsyncReader & ~Copyable,
//    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable
//>: Middleware
//where
//    RequestConcludingAsyncReader.Underlying.ReadElement == UInt8,
//    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
//    ResponseConcludingAsyncWriter.Underlying.WriteElement == UInt8,
//    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
//{
//    typealias Input = RequestResponseMiddlewareBox<RequestConcludingAsyncReader, ResponseConcludingAsyncWriter>
//    typealias NextInput = RequestResponseMiddlewareBox<
//        HTTPRequestLoggingConcludingAsyncReader<RequestConcludingAsyncReader>,
//        HTTPResponseLoggingConcludingAsyncWriter<ResponseConcludingAsyncWriter>
//    >
//
//    let logger: Logger
//
//    init(
//        requestConcludingAsyncReaderType: RequestConcludingAsyncReader.Type = RequestConcludingAsyncReader.self,
//        responseConcludingAsyncWriterType: ResponseConcludingAsyncWriter.Type = ResponseConcludingAsyncWriter.self,
//        logger: Logger
//    ) {
//        self.logger = logger
//    }
//
//    func intercept(
//        input: consuming Input,
//        next: (consuming NextInput) async throws -> Void
//    ) async throws {
//        try await input.withContents { request, context, requestReader, responseSender in
//            self.logger.info("Received request \(request.path ?? "unknown" ) \(request.method.rawValue)")
//            defer {
//                self.logger.info("Finished request \(request.path ?? "unknown" ) \(request.method.rawValue)")
//            }
//            let wrappedReader = HTTPRequestLoggingConcludingAsyncReader(
//                base: requestReader,
//                logger: self.logger
//            )
//
//            var maybeSender = Optional(responseSender)
//            let requestResponseBox = RequestResponseMiddlewareBox(
//                request: request,
//                requestContext: context,
//                requestReader: wrappedReader,
//                responseSender: HTTPResponseSender { [logger] response in
//                    if let sender = maybeSender.take() {
//                        logger.info("Sending response \(response)")
//                        let writer = try await sender.send(response)
//                        return HTTPResponseLoggingConcludingAsyncWriter(
//                            base: writer,
//                            logger: logger
//                        )
//                    } else {
//                        fatalError("Called closure more than once")
//                    }
//                } sendInformational: { response in
//                    self.logger.info("Sending informational response \(response)")
//                    try await maybeSender?.sendInformational(response)
//                }
//            )
//            try await next(requestResponseBox)
//        }
//    }
//}
//
//@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
//struct HTTPRequestLoggingConcludingAsyncReader<
//    Base: ConcludingAsyncReader & ~Copyable
//>: ConcludingAsyncReader, ~Copyable
//where
//    Base.Underlying.ReadElement == UInt8,
//    Base.FinalElement == HTTPFields?
//{
//    typealias Underlying = RequestBodyAsyncReader
//    typealias FinalElement = HTTPFields?
//
//    struct RequestBodyAsyncReader: AsyncReader, ~Copyable, ~Escapable {
//        typealias ReadElement = Base.Underlying.ReadElement
//        typealias ReadFailure = Base.Underlying.ReadFailure
//
//        private var underlying: Base.Underlying
//        private let logger: Logger
//
//        @_lifetime(copy underlying)
//        init(underlying: consuming Base.Underlying, logger: Logger) {
//            self.underlying = underlying
//            self.logger = logger
//        }
//
//        #if compiler(<6.3)
//        @_lifetime(&self)
//        #endif
//        mutating func read<Return, Failure: Error>(
//            maximumCount: Int?,
//            body: nonisolated(nonsending) (consuming Span<ReadElement>) async throws(Failure) -> Return
//        ) async throws(EitherError<ReadFailure, Failure>) -> Return {
//            return try await self.underlying.read(maximumCount: maximumCount) { span throws(Failure) in
//                logger.info("Received next chunk \(span.count)")
//                return try await body(span)
//            }
//        }
//    }
//
//    private var base: Base
//    private let logger: Logger
//
//    init(base: consuming Base, logger: Logger) {
//        self.base = base
//        self.logger = logger
//    }
//
//    consuming func consumeAndConclude<Return, Failure: Error>(
//        body: nonisolated(nonsending) (consuming sending Underlying) async throws(Failure) -> Return
//    ) async throws(Failure) -> (Return, FinalElement) {
//        let (result, trailers) = try await self.base.consumeAndConclude { reader throws(Failure) in
//            let wrappedReader = RequestBodyAsyncReader(
//                underlying: reader,
//                logger: logger
//            )
//            return try await body(wrappedReader)
//        }
//
//        if let trailers {
//            self.logger.info("Received request trailers \(trailers)")
//        } else {
//            self.logger.info("Received no request trailers")
//        }
//
//        return (result, trailers)
//    }
//}
//
//@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
//struct HTTPResponseLoggingConcludingAsyncWriter<
//    Base: ConcludingAsyncWriter & ~Copyable
//>: ConcludingAsyncWriter, ~Copyable
//where
//    Base.Underlying.WriteElement == UInt8,
//    Base.FinalElement == HTTPFields?
//{
//    typealias Underlying = ResponseBodyAsyncWriter
//    typealias FinalElement = HTTPFields?
//
//    struct ResponseBodyAsyncWriter: AsyncWriter, ~Copyable, ~Escapable {
//        typealias WriteElement = Base.Underlying.WriteElement
//        typealias WriteFailure = Base.Underlying.WriteFailure
//
//        private var underlying: Base.Underlying
//        private let logger: Logger
//
//        @_lifetime(copy underlying)
//        init(underlying: consuming Base.Underlying, logger: Logger) {
//            self.underlying = underlying
//            self.logger = logger
//        }
//
//        @_lifetime(self: copy self)
//        mutating func write<Result, Failure: Error>(
//            _ body: (inout OutputSpan<WriteElement>) async throws(Failure) -> Result
//        ) async throws(EitherError<WriteFailure, Failure>) -> Result {
//            try await self.underlying.write { span throws(Failure) in
//                self.logger.info("Wrote next chunk \(span.count)")
//                return try await body(&span)
//            }
//        }
//
//        @_lifetime(self: copy self)
//        mutating func write(
//            _ span: Span<WriteElement>
//        ) async throws(EitherError<WriteFailure, AsyncWriterWroteShortError>) {
//            self.logger.info("Wrote next chunk")
//            try await self.underlying.write(span)
//        }
//    }
//
//    private var base: Base
//    private let logger: Logger
//
//    init(base: consuming Base, logger: Logger) {
//        self.base = base
//        self.logger = logger
//    }
//
//    consuming func produceAndConclude<Return>(
//        body: (consuming sending ResponseBodyAsyncWriter) async throws -> (Return, HTTPFields?)
//    ) async throws -> Return {
//        let logger = self.logger
//        return try await self.base.produceAndConclude { writer in
//            let wrappedAsyncWriter = ResponseBodyAsyncWriter(underlying: writer, logger: logger)
//            let (result, trailers) = try await body(wrappedAsyncWriter)
//
//            if let trailers {
//                logger.info("Wrote response trailers \(trailers)")
//            } else {
//                logger.info("Wrote no response trailers")
//            }
//            return (result, trailers)
//        }
//    }
//}
