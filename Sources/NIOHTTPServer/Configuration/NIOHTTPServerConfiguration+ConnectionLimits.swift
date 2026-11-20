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

@available(anyAppleOS 27.0, *)
extension NIOHTTPServerConfiguration {
    /// Limits on the connections the server admits.
    ///
    /// - Note: TCP and QUIC limits are tracked differently, because of how each protocol receives new connections:
    ///   - For TCP, we set up exactly one listener socket per bind target. The listener socket sees every incoming
    ///     connection and distributes it across the server's event loops. Therefore, the limits can be enforced across
    ///     all threads together. For example, setting ``TCPConnectionLimits/maxConnections`` to 10,000 means that
    ///     10,000 TCP connections can be open at any time, per bind target.
    ///
    ///   - For QUIC, there is no dedicated listener socket for just accepting connections. Each UDP socket receives
    ///     datagrams directly and serves its connections on its own thread. Therefore, the limits apply **separately on
    ///     each UDP socket** serving a bind target. By default, a bind target is served by exactly one UDP socket, so
    ///     the limits apply identically like TCP. However, if the `datagramSocketGroupFactory` configuration is set and
    ///     the socket group's `socketCount` is greater than 1, multiple UDP sockets serve each bind target. For
    ///     example, with 8 UDP sockets per bind target, setting ``QUICConnectionLimits/maxConnections`` to 10,000 means
    ///     that 80,000 QUIC connections can be open at any time, per bind target.
    public struct ConnectionLimits: Sendable, Hashable {
        /// Limits on the TCP connections the server admits.
        ///
        /// - Note: ``NIOHTTPServerConfiguration/supportedHTTPVersions`` must contain
        ///   ``NIOHTTPServerConfiguration/HTTPVersion/http1_1`` and/or ``NIOHTTPServerConfiguration/HTTPVersion/http2``
        ///   for this configuration to be in effect.
        public var tcp: TCPConnectionLimits?

        #if HTTP3
        /// Limits on the QUIC connections the server admits.
        ///
        /// - Note: ``NIOHTTPServerConfiguration/supportedHTTPVersions`` must contain
        ///   ``NIOHTTPServerConfiguration/HTTPVersion/http3`` for this configuration to be in effect.
        public var quic: QUICConnectionLimits?
        #endif  // HTTP3

        /// The default limits. Uses the following default values:
        /// - ``tcp``: ``NIOHTTPServerConfiguration/TCPConnectionLimits/defaults``
        /// - ``quic``: ``NIOHTTPServerConfiguration/QUICConnectionLimits/defaults``
        public static var defaults: Self {
            #if HTTP3
            Self.init(tcp: .defaults, quic: .defaults)
            #else
            Self.init(tcp: .defaults)
            #endif  // HTTP3
        }
    }

    /// Limits on the number of TCP connections and in-progress TLS handshakes.
    public struct TCPConnectionLimits: Sendable, Hashable {
        /// The maximum number of connections that may be open at once, including connections still completing their
        /// handshake. `nil` means unlimited.
        ///
        /// When this limit is reached, the listener socket stops accepting new connections until existing connections
        /// close.
        ///
        /// - Precondition: Must be greater than 0 if non-`nil`.
        public var maxConnections: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// The maximum number of new connections accepted per second. A burst of up to this many is accepted at once;
        /// after that, capacity refills at this rate. `nil` means unlimited.
        ///
        /// When the rate is exhausted, the listener socket holds back `accept()` calls.
        ///
        /// - Precondition: Must be between 1 and 1,000,000,000 if non-`nil`.
        public var newConnectionsPerSecond: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// The maximum number of connections that can be in the TLS handshake stage at once. `nil` means unlimited.
        ///
        /// When this limit is reached, the listener socket closes new connections as soon as they are accepted.
        ///
        /// - Note: This limit can only be set when ``NIOHTTPServerConfiguration/transportSecurity`` is TLS or mTLS.
        ///
        /// - Precondition: Must be greater than 0 if non-`nil`.
        public var maxConcurrentTLSHandshakes: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// Whether any of the limits are set.
        var isEnabled: Bool {
            self.maxConnections != nil || self.newConnectionsPerSecond != nil || self.maxConcurrentTLSHandshakes != nil
        }

        /// Creates limits on the number of open connections, the rate of new connections, and the number of concurrent
        /// TLS handshakes in progress.
        ///
        /// - Parameters:
        ///   - maxConnections: The maximum number of connections that may be open at once.
        ///   - newConnectionsPerSecond: The maximum number of new connections accepted per second.
        ///   - maxConcurrentTLSHandshakes: The maximum number of connections that can be in the TLS handshake stage at
        ///     once.
        ///
        /// - Throws: If any limit is out of range.
        init(
            maxConnections: Int? = nil,
            newConnectionsPerSecond: Int? = nil,
            maxConcurrentTLSHandshakes: Int? = nil
        ) throws {
            try Self.validate(
                maxConnections: maxConnections,
                newConnectionsPerSecond: newConnectionsPerSecond,
                maxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
            )

            self.init(
                validatedMaxConnections: maxConnections,
                validatedNewConnectionsPerSecond: newConnectionsPerSecond,
                validatedMaxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
            )
        }

        /// Creates a ``TCPConnectionLimits`` value from limits that are known to be valid.
        private init(
            validatedMaxConnections maxConnections: Int?,
            validatedNewConnectionsPerSecond newConnectionsPerSecond: Int?,
            validatedMaxConcurrentTLSHandshakes maxConcurrentTLSHandshakes: Int?
        ) {
            self.maxConnections = maxConnections
            self.newConnectionsPerSecond = newConnectionsPerSecond
            self.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
        }

        /// Validates the limits.
        ///
        /// - Throws: If any limit is out of range.
        private static func validate(
            maxConnections: Int?,
            newConnectionsPerSecond: Int?,
            maxConcurrentTLSHandshakes: Int?
        ) throws {
            if let maxConnections, maxConnections <= 0 {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.tcp.maxConnections",
                    requirement: "greater than 0"
                )
            }

            if let newConnectionsPerSecond, !(1...1_000_000_000).contains(newConnectionsPerSecond) {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.tcp.newConnectionsPerSecond",
                    requirement: "between 1 and 1,000,000,000"
                )
            }

            if let maxConcurrentTLSHandshakes, maxConcurrentTLSHandshakes <= 0 {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.tcp.maxConcurrentTLSHandshakes",
                    requirement: "greater than 0"
                )
            }
        }

        /// Validates the limits, and triggers a `preconditionFailure` if they are invalid.
        private func preconditionValidLimits() {
            do {
                try Self.validate(
                    maxConnections: self.maxConnections,
                    newConnectionsPerSecond: self.newConnectionsPerSecond,
                    maxConcurrentTLSHandshakes: self.maxConcurrentTLSHandshakes
                )
            } catch {
                preconditionFailure("\(error)")
            }
        }

        /// The default limits for TCP connections:
        /// - 100,000 open connections
        /// - 10,000 new connections per second
        /// - No limit on the number of concurrent TLS handshakes in progress.
        public static var defaults: Self {
            Self(
                validatedMaxConnections: 100_000,
                validatedNewConnectionsPerSecond: 10_000,
                validatedMaxConcurrentTLSHandshakes: nil
            )
        }
    }

    #if HTTP3
    /// Limits on the number of QUIC connections and in-progress TLS handshakes.
    public struct QUICConnectionLimits: Sendable, Hashable {
        /// The maximum number of connections that may be open at once, including connections still completing their
        /// handshake. `nil` means unlimited.
        ///
        /// When this limit is reached, the QUIC socket drops new connection attempts.
        ///
        /// - Precondition: Must be greater than 0 if non-`nil`.
        public var maxConnections: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// The maximum number of new connections accepted per second. A burst of up to this many is accepted at once;
        /// after that, capacity refills at this rate. `nil` means unlimited.
        ///
        /// When the rate is exhausted, the QUIC socket drops new connection attempts, until the rate limiter permits.
        ///
        /// - Precondition: Must be between 1 and 1,000,000,000 if non-`nil`.
        public var newConnectionsPerSecond: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// The maximum number of connections that can be in the TLS handshake stage at once. `nil` means unlimited.
        ///
        /// When this limit is reached, the QUIC socket drops new connection attempts.
        ///
        /// - Precondition: Must be greater than 0 if non-`nil`.
        public var maxConcurrentTLSHandshakes: Int? {
            didSet {
                self.preconditionValidLimits()
            }
        }

        /// Whether any of the limits are set.
        var isEnabled: Bool {
            self.maxConnections != nil || self.newConnectionsPerSecond != nil || self.maxConcurrentTLSHandshakes != nil
        }

        /// Creates limits on the number of open connections, the rate of new connections, and the number of concurrent
        /// TLS handshakes in progress.
        ///
        /// - Parameters:
        ///   - maxConnections: The maximum number of connections that may be open at once.
        ///   - newConnectionsPerSecond: The maximum number of new connections accepted per second.
        ///   - maxConcurrentTLSHandshakes: The maximum number of connections that can be in the TLS handshake stage at
        ///     once.
        ///
        /// - Throws: If any limit is out of range.
        init(
            maxConnections: Int? = nil,
            newConnectionsPerSecond: Int? = nil,
            maxConcurrentTLSHandshakes: Int? = nil
        ) throws {
            try Self.validate(
                maxConnections: maxConnections,
                newConnectionsPerSecond: newConnectionsPerSecond,
                maxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
            )

            self.init(
                validatedMaxConnections: maxConnections,
                validatedNewConnectionsPerSecond: newConnectionsPerSecond,
                validatedMaxConcurrentTLSHandshakes: maxConcurrentTLSHandshakes
            )
        }

        /// Creates a ``QUICConnectionLimits`` value from limits that are known to be valid.
        private init(
            validatedMaxConnections maxConnections: Int?,
            validatedNewConnectionsPerSecond newConnectionsPerSecond: Int?,
            validatedMaxConcurrentTLSHandshakes maxConcurrentTLSHandshakes: Int?
        ) {
            self.maxConnections = maxConnections
            self.newConnectionsPerSecond = newConnectionsPerSecond
            self.maxConcurrentTLSHandshakes = maxConcurrentTLSHandshakes
        }

        /// Validates the limits.
        ///
        /// - Throws: If any limit is out of range.
        private static func validate(
            maxConnections: Int?,
            newConnectionsPerSecond: Int?,
            maxConcurrentTLSHandshakes: Int?
        ) throws {
            if let maxConnections, maxConnections <= 0 {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.quic.maxConnections",
                    requirement: "greater than 0"
                )
            }

            if let newConnectionsPerSecond, !(1...1_000_000_000).contains(newConnectionsPerSecond) {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.quic.newConnectionsPerSecond",
                    requirement: "between 1 and 1,000,000,000"
                )
            }

            if let maxConcurrentTLSHandshakes, maxConcurrentTLSHandshakes <= 0 {
                throw NIOHTTPServerConfigurationError.invalidConnectionLimit(
                    name: "connectionLimits.quic.maxConcurrentTLSHandshakes",
                    requirement: "greater than 0"
                )
            }
        }

        /// Validates the limits, and triggers a `preconditionFailure` if they are invalid.
        private func preconditionValidLimits() {
            do {
                try Self.validate(
                    maxConnections: self.maxConnections,
                    newConnectionsPerSecond: self.newConnectionsPerSecond,
                    maxConcurrentTLSHandshakes: self.maxConcurrentTLSHandshakes
                )
            } catch {
                preconditionFailure("\(error)")
            }
        }

        /// The default limits for QUIC connections:
        /// - 10,000 open connections
        /// - 1,000 new connections per second
        /// - No limit on the number of concurrent TLS handshakes in progress.
        ///
        /// - Note: The default limits are lower here compared to ``TCPConnectionLimits/defaults``, as these limits
        ///   apply individually on each UDP socket created per bind target. See the note in ``ConnectionLimits``.
        public static var defaults: Self {
            Self(
                validatedMaxConnections: 10_000,
                validatedNewConnectionsPerSecond: 1_000,
                validatedMaxConcurrentTLSHandshakes: nil
            )
        }
    }
    #endif  // HTTP3
}
