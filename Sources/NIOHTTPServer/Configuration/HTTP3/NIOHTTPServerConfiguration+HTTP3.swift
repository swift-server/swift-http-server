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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration {
    /// Configuration for HTTP/3.
    public struct HTTP3: Sendable, Hashable {
        /// QUIC transport configuration.
        public var quicConfiguration: QUICConfiguration = .defaults

        /// HTTP/3 protocol-level configuration.
        public var protocolConfiguration: ProtocolConfiguration = .defaults

        /// HTTP/3 connection settings exchanged with the client during connection establishment.
        public var connectionSettings: ConnectionSettings = .defaults

        /// Creates an HTTP/3 configuration with the given HTTP/3 protocol configuration, connection settings, and QUIC
        /// transport configuration.
        ///
        /// - Parameters:
        ///   - quicConfiguration: QUIC transport parameters.
        ///   - protocolConfiguration: Settings that control HTTP/3 protocol behaviour.
        ///   - connectionSettings: HTTP/3 connection-level settings exchanged with the client.
        public init(
            quicConfiguration: QUICConfiguration,
            protocolConfiguration: ProtocolConfiguration,
            connectionSettings: ConnectionSettings,
        ) {
            self.protocolConfiguration = protocolConfiguration
            self.connectionSettings = connectionSettings
            self.quicConfiguration = quicConfiguration
        }

        /// The default HTTP/3 configuration.
        ///
        /// Uses the default configurations of the sub-components:
        /// - `quicConfiguration`: ``QUICConfiguration/defaults``.
        /// - `protocolConfiguration`: ``ProtocolConfiguration/defaults``.
        /// - `connectionSettings`: ``ConnectionSettings/defaults``.
        public static var defaults: Self {
            Self(
                quicConfiguration: .defaults,
                protocolConfiguration: .defaults,
                connectionSettings: .defaults,
            )
        }

        // The fallback connection RTT to use if there is an error obtaining the RTT estimate channel option.
        static var fallbackConnectionRTT: TimeAmount {
            .milliseconds(100)
        }
    }
}
