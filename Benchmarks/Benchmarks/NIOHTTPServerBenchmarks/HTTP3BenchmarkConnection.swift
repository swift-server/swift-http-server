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

import HTTP3
import HTTPTypes
import NIOCore
import NIOHTTP3
import NIOHTTPTypes
import NIOQUIC

struct HTTP3BenchmarkConnection {
    private static let request = HTTPRequest(method: .get, scheme: "https", authority: "127.0.0.1", path: "/")

    private let connection: HTTP3ClientConnection<Void, QUICStreamCreator>

    init(connection: HTTP3ClientConnection<Void, QUICStreamCreator>) {
        self.connection = connection
    }

    func get() async throws {
        let stream = try await self.connection.createRequestStream { parameters in
            let streamChannel = parameters.channel
            return streamChannel.eventLoop.makeCompletedFuture {
                try NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>(
                    wrappingChannelSynchronously: streamChannel,
                    configuration: .init(isOutboundHalfClosureEnabled: true)
                )
            }
        }

        try await stream.executeThenClose { inbound, outbound in
            try await outbound.write(contentsOf: [.head(Self.request), .end(nil)])
            var status: HTTPResponse.Status?
            for try await part in inbound {
                switch part {
                case .head(let response):
                    status = response.status
                case .body:
                    continue
                case .end:
                    guard status == .ok else {
                        throw BenchmarkError.unexpectedResponseStatus(status)
                    }
                    return
                }
            }
            throw BenchmarkError.responseEndedEarly
        }
    }
}

@available(*, unavailable)
extension HTTP3BenchmarkConnection: Sendable {}
