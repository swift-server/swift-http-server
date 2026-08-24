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
import NIOPosix
import System

@available(anyAppleOS 26.0, *)
extension ServerBootstrap {
    /// Binds `bootstrap` to the given ``NIOHTTPServerConfiguration/BindTarget`` by dispatching to the matching
    /// `ServerBootstrap.bind` overload: the host-and-port variant or the Unix domain socket variant.
    ///
    /// `bootstrap` is taken as a `sending` parameter because `ServerBootstrap` is not `Sendable`; passing it into
    /// the underlying `async` bind hands it off to the bind's isolation region. This is a `static` helper rather than
    /// an instance method because `self` on an instance method cannot be marked `sending`.
    ///
    /// - Parameters:
    ///   - bootstrap: The bootstrap to bind. Ownership is transferred to this call.
    ///   - bindTarget: The address to bind to.
    ///   - childChannelInitializer: The initializer invoked for each accepted child channel.
    /// - Returns: The bound `NIOAsyncChannel` producing the child channel outputs.
    static func bind<Output: Sendable>(
        _ bootstrap: sending ServerBootstrap,
        to bindTarget: NIOHTTPServerConfiguration.BindTarget,
        childChannelInitializer: @escaping @Sendable (any Channel) -> EventLoopFuture<Output>
    ) async throws -> NIOAsyncChannel<Output, Never> {
        switch bindTarget.backing {
        case .hostAndPort(let host, let port):
            return try await bootstrap.bind(
                host: host,
                port: port,
                childChannelInitializer: childChannelInitializer
            )
        case .unixDomainSocket(let path):
            return try await bootstrap.bind(
                unixDomainSocketPath: path.string,
                childChannelInitializer: childChannelInitializer
            )
        }
    }
}
