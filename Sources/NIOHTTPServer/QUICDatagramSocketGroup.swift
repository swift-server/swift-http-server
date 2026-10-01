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

#if HTTP3
public import Logging
public import NIOCore
public import NIOQUIC

/// Used to bootstrap multiple datagram sockets sharing a single port for multithreaded QUIC.
@available(anyAppleOS 27.0, *)
@_spi(QUICDatagramSockets)
public protocol QUICDatagramSocketGroup: Sendable {
    /// How many sockets to bind for this bind target.
    ///
    /// This value is read once, when the group is built during server bootstrap.
    ///
    /// - Throws: Server bootstrap will throw if `socketCount` returns a value outside of `1...availableEventLoops`.
    var socketCount: Int { get }

    /// Called once the socket with `socketIndex` is bound, on the event loop that owns it.
    ///
    /// Called exactly once for each of the group's sockets, with each index in `0..<socketCount`. Sockets bind
    /// concurrently, so the order of the calls is undefined.
    ///
    /// Throwing here aborts the bind: the channel will be closed and the server will fail to start.
    ///
    /// - Parameters:
    ///   - socket: The bound socket, which the server owns and will close.
    ///   - socketIndex: Index between `0..<socketCount` identifying this socket within the group.
    ///
    /// - Warning: The socket handle is technically only valid for the duration of this call. The NIO channel
    ///            maintains ownership of the socket and will close it when the channel is closed.
    func socketBound(_ socket: NIOBSDSocket.Handle, socketIndex: Int) throws

    /// The connection ID generator for the socket at `socketIndex`.
    func makeConnectionIDGenerator(socketIndex: Int) -> any QUICConnectionID.Generator
}

@available(anyAppleOS 27.0, *)
@_spi(QUICDatagramSockets)
extension QUICDatagramSocketGroup {
    /// Default implementation: returns the default, random connection ID generator.
    public func makeConnectionIDGenerator(socketIndex: Int) -> any QUICConnectionID.Generator {
        QUICConnectionID.RandomGenerator()
    }
}

/// Provides a socket group used to bootstrap a bind target, or `nil` to fall back to single socket behavior.
@available(anyAppleOS 27.0, *)
@_spi(QUICDatagramSockets)
public struct QUICDatagramSocketGroupFactory: Sendable, Hashable {
    /// Because this type is just a wrapper around a closure, we need something to use for `Hashable` conformance.
    private final class Identity: Sendable {}

    private let identity = Identity()
    private let makeSocketGroup: @Sendable (Int, Logger) throws -> (any QUICDatagramSocketGroup)?

    /// - Parameter makeSocketGroup: Returns `nil` to decline, which binds a single socket with the default
    ///   generator, or throws to fail server bootstrap.
    public init(
        _ makeSocketGroup:
            @escaping @Sendable (_ availableEventLoops: Int, _ logger: Logger) throws -> (any QUICDatagramSocketGroup)?
    ) {
        self.makeSocketGroup = makeSocketGroup
    }

    func makeSocketGroup(
        availableEventLoops: Int,
        logger: Logger
    ) throws -> (any QUICDatagramSocketGroup)? {
        try self.makeSocketGroup(availableEventLoops, logger)
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.identity === rhs.identity
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(ObjectIdentifier(self.identity))
    }
}
#endif  // HTTP3
