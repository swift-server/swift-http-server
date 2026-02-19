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

import NIOCore
import NIOHTTPServer
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension Channel {
    /// Adds HTTP/1.1 client handlers to the pipeline.
    func configureTestHTTP1ClientPipeline() -> EventLoopFuture<NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>> {
        self.eventLoop.makeCompletedFuture {
            try self.pipeline.syncOperations.addHTTPClientHandlers()
            try self.pipeline.syncOperations.addHandler(HTTP1ToHTTPClientCodec())

            return try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                wrappingChannelSynchronously: self,
                configuration: .init(isOutboundHalfClosureEnabled: true)
            )
        }
    }
}

@available(macOS 26.2, iOS 26.2, watchOS 26.2, tvOS 26.2, visionOS 26.2, *)
extension ClientBootstrap {
    /// Connects to the provided `serverAddress` and provides a `NIOAsyncChannel`. With this ``NIOAsyncChannel``, one
    /// can write `HTTPRequestPart`s to the server and observe `HTTPResponsePart`s from the inbound stream of the
    /// channel.
    func connectToTestHTTP1Server(
        at serverAddress: NIOHTTPServer.SocketAddress
    ) async throws -> NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart> {
        try await self.connect(to: try .init(ipAddress: serverAddress.host, port: serverAddress.port)) { channel in
            channel.configureTestHTTP1ClientPipeline()
        }
    }
}
