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

extension NIOAsyncTestingChannel {
    /// Forwards all of our outbound writes to `other` and vice-versa.
    func glueTo(_ other: NIOAsyncTestingChannel) async throws {
        await withThrowingTaskGroup { group in
            // 1. Forward all `self` writes to `other`
            group.addTask {
                while !Task.isCancelled {
                    let ourPart = try await self.waitForOutboundWrite(as: ByteBuffer.self)
                    try await other.writeInbound(ourPart)
                }
            }

            // 2. Forward all `other` writes to `self`
            group.addTask {
                while !Task.isCancelled {
                    let otherPart = try await other.waitForOutboundWrite(as: ByteBuffer.self)
                    try await self.writeInbound(otherPart)
                }
            }
        }
    }

    /// Creates a connection channel that can be written to the server channel to simulate an incoming connection.
    static func createActiveChannel() async throws -> NIOAsyncTestingChannel {
        let serverTestConnectionChannel = NIOAsyncTestingChannel()

        let connectionPromise = serverTestConnectionChannel.eventLoop.makePromise(of: Void.self)
        // The `to` address has no significance here, it is just a random address. We are only interested in making the
        // channel *active*; calling `connect` is the way to achieve that.
        serverTestConnectionChannel.connect(
            to: try .init(ipAddress: "127.0.0.1", port: 8000),
            promise: connectionPromise
        )
        try await connectionPromise.futureResult.get()

        return serverTestConnectionChannel
    }
}
