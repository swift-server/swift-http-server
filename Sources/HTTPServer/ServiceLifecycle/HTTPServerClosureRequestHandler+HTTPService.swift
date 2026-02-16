//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2026 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

#if ServiceLifecycle
public import AsyncStreaming
public import HTTPTypes

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension HTTPService
where
    Handler == HTTPServerClosureRequestHandler<
        Server.RequestReader,
        Server.RequestReader.Underlying,
        Server.ResponseWriter,
        Server.ResponseWriter.Underlying
    >
{
    /// - Parameters:
    ///   - server: The underlying HTTPServer instance.
    ///   - serverHandler: The request handler closure.
    ///   - gracefulShutdownHandler: A closure to execute upon graceful shutdown.
    public init(
        server: Server,
        serverHandler:
            nonisolated(nonsending) @Sendable @escaping (
                _ request: HTTPRequest,
                _ requestContext: HTTPRequestContext,
                _ requestBodyAndTrailers: consuming sending Server.RequestReader,
                _ responseSender: consuming sending HTTPResponseSender<Server.ResponseWriter>
            ) async throws -> Void,
        gracefulShutdownHandler: @Sendable @escaping () -> Void = {}
    ) {
        self.server = server
        self.serverHandler = HTTPServerClosureRequestHandler(handler: serverHandler)
        self.gracefulShutdownHandler = gracefulShutdownHandler
    }
}
#endif  // ServiceLifecycle
