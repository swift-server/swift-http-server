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
import NIOCore
import NIOHTTP3

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration {
    /// Configuration for HTTP/3.
    public struct HTTP3: Sendable, Hashable {
        /// If true, Huffman encoding will be used where applicable, e.g. for header field sections.
        ///
        /// - Note: Huffman encoding will not be used if it would result in a larger payload than not using it, even if
        ///   this property is true.
        public var preferHuffmanEncoding = true

        /// QUIC transport configuration.
        public var quicConfiguration: QUICConfiguration = .defaults

        /// HTTP/3 connection settings exchanged with the client during connection establishment.
        public var connectionSettings: ConnectionSettings = .defaults

        #if UnstableHTTPDatagrams
        /// The HTTP/3 datagram configuration. If set to `nil`, the server will not advertise support for receiving
        /// HTTP/3 datagrams.
        public var datagramConfiguration: DatagramConfiguration? = .defaults

        /// Creates an HTTP/3 configuration.
        ///
        /// - Parameters:
        ///   - preferHuffmanEncoding: Whether Huffman encoding is used where applicable.
        ///   - quicConfiguration: QUIC transport parameters.
        ///   - connectionSettings: HTTP/3 connection-level settings exchanged with the client.
        ///   - datagramConfiguration: The HTTP/3 datagram configuration. If set to `nil`, the server will not advertise
        ///     support for receiving HTTP/3 datagrams.
        public init(
            preferHuffmanEncoding: Bool,
            quicConfiguration: QUICConfiguration,
            connectionSettings: ConnectionSettings,
            datagramConfiguration: DatagramConfiguration? = .defaults
        ) {
            self.preferHuffmanEncoding = preferHuffmanEncoding
            self.quicConfiguration = quicConfiguration
            self.connectionSettings = connectionSettings
            self.datagramConfiguration = datagramConfiguration
        }
        #else
        /// Creates an HTTP/3 configuration.
        ///
        /// - Parameters:
        ///   - preferHuffmanEncoding: Whether Huffman encoding is used where applicable.
        ///   - quicConfiguration: QUIC transport parameters.
        ///   - connectionSettings: HTTP/3 connection-level settings exchanged with the client.
        public init(
            preferHuffmanEncoding: Bool,
            quicConfiguration: QUICConfiguration,
            connectionSettings: ConnectionSettings,
        ) {
            self.preferHuffmanEncoding = preferHuffmanEncoding
            self.quicConfiguration = quicConfiguration
            self.connectionSettings = connectionSettings
        }
        #endif  // UnstableHTTPDatagrams

        /// The default HTTP/3 configuration.
        ///
        /// Uses the default configurations of the sub-components:
        /// - `preferHuffmanEncoding`: `true`.
        /// - `quicConfiguration`: ``QUICConfiguration/defaults``.
        /// - `connectionSettings`: ``ConnectionSettings/defaults``.
        /// - `datagramConfiguration`: ``DatagramConfiguration/defaults``.
        public static var defaults: Self {
            #if UnstableHTTPDatagrams
            Self(
                preferHuffmanEncoding: true,
                quicConfiguration: .defaults,
                connectionSettings: .defaults,
                datagramConfiguration: .defaults
            )
            #else
            Self(
                preferHuffmanEncoding: true,
                quicConfiguration: .defaults,
                connectionSettings: .defaults
            )
            #endif  // UnstableHTTPDatagrams
        }

        // The fallback connection RTT to use if there is an error obtaining the RTT estimate channel option.
        static var fallbackConnectionRTT: TimeAmount {
            .milliseconds(100)
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTP3.HTTP3ServerConfiguration {
    init(_ configuration: NIOHTTPServerConfiguration.HTTP3) {
        self = .defaults
        self.preferHuffmanEncoding = configuration.preferHuffmanEncoding

        #if UnstableHTTPDatagrams
        if let datagramConfiguration = configuration.datagramConfiguration {
            self.maxBufferedDatagramBytes = datagramConfiguration.maxBufferedDatagramBytes
        }
        #endif  // UnstableHTTPDatagrams
    }
}
#endif  // HTTP3
