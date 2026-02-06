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

public import AsyncStreaming
public import HTTPTypes
public import Middleware
import HTTPServer

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
public struct RouteHandlerMiddleware<
    RequestConcludingAsyncReader: ConcludingAsyncReader & ~Copyable,
    ResponseConcludingAsyncWriter: ConcludingAsyncWriter & ~Copyable,
>: Middleware, Sendable
where
    RequestConcludingAsyncReader.Underlying: AsyncReader<UInt8, any Error>,
    RequestConcludingAsyncReader.FinalElement == HTTPFields?,
    ResponseConcludingAsyncWriter.Underlying: AsyncWriter<UInt8, any Error>,
    ResponseConcludingAsyncWriter.FinalElement == HTTPFields?
{
    public typealias Input = RequestResponseMiddlewareBox<RequestConcludingAsyncReader, ResponseConcludingAsyncWriter>
    public typealias NextInput = Never

    public func intercept(
        input: consuming Input,
        next: (consuming NextInput) async throws -> Void
    ) async throws {
        try await input.withContents { request, _, requestReader, responseSender in
            var maybeReader = Optional(requestReader)
            try await responseSender.send(HTTPResponse(status: .accepted))
                .produceAndConclude { responseBodyAsyncWriter in
                    var responseBodyAsyncWriter = responseBodyAsyncWriter
                    if let reader = maybeReader.take() {
                        _ = try await reader.consumeAndConclude { bodyAsyncReader in
                            var bodyAsyncReader = bodyAsyncReader
                            try await bodyAsyncReader.read(maximumCount: nil) { span in
                                try await responseBodyAsyncWriter.write(span)
                            }
                        }
                        return HTTPFields(dictionaryLiteral: (HTTPField.Name.acceptEncoding, "encoding"))
                    } else {
                        fatalError("Closure run more than once")
                    }
                }
        }
    }
}
