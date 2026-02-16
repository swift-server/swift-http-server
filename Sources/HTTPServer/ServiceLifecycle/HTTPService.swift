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
public import ServiceLifecycle

/// A wrapper over HTTPServer that integrates with ServiceLifecycle.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
public struct HTTPService<
    Server: HTTPServer & GracefulShutdownService,
    Handler: HTTPServerRequestHandler
>: Service
where
    Server.RequestReader == Handler.RequestReader,
    Server.ResponseWriter == Handler.ResponseWriter
{
    let server: Server
    let serverHandler: Handler
    let gracefulShutdownHandler: @Sendable () -> Void

    /// - Parameters:
    ///   - server: The underlying HTTPServer instance.
    ///   - serverHandler: The request handler that `server` will use.
    ///   - onGracefulShutdown: A closure to execute upon graceful shutdown.
    ///
    /// - Note: The `onGracefulShutdown` closure will be called *after* initiating graceful shutdown on `server`.
    public init(
        server: Server,
        serverHandler: Handler,
        onGracefulShutdown gracefulShutdownHandler: @Sendable @escaping () -> Void = {}
    ) {
        self.server = server
        self.serverHandler = serverHandler
        self.gracefulShutdownHandler = gracefulShutdownHandler
    }

    /// Runs the HTTP server and handles graceful shutdown when signaled.
    public func run() async throws {
        try await withGracefulShutdownHandler(
            operation: {
                try await self.server.serve(handler: self.serverHandler)
            },
            onGracefulShutdown: {
                self.server.beginGracefulShutdown()
                // Call the user-provided graceful shutdown handler
                self.gracefulShutdownHandler()
            }
        )
    }
}
#endif  // ServiceLifecycle
