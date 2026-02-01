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

import NIOCore
import NIOEmbedded
import NIOHTTPTypes

@testable import HTTPServer
@testable import NIOHTTPServer

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension NIOHTTPServer {
    func serveInsecureHTTP1_1WithTestChannel(
        testChannel: NIOAsyncTestingChannel,
        handler: some HTTPServerRequestHandler<RequestReader, ResponseWriter>
    ) async throws {
        // The server requires a NIOAsyncChannel, so we create one from the test channel
        let serverTestAsyncChannel = try await testChannel.eventLoop.submit {
            try NIOAsyncChannel<NIOAsyncChannel<HTTPRequestPart, HTTPResponsePart>, Never>(
                wrappingChannelSynchronously: testChannel,
                configuration: .init()
            )
        }.get()

        // Trick the server into thinking it's been bound to an address so that we don't leak the listening address
        // promise. In reality, the server hasn't been bound to any address: we will manually feed in requests and
        // observe responses.
        try self.addressBound(.init(ipAddress: "127.0.0.1", port: 8000))
        _ = try await self.listeningAddress

        try await _serveInsecureHTTP1_1(serverChannel: serverTestAsyncChannel, handler: handler)
    }
}
