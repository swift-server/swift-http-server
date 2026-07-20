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

#if HTTP3 && Configuration
public import Configuration

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3 {
    /// Initialize an HTTP/3 configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// HTTP/3 configuration contains three sub-scopes. All keys are optional and resolve to their default values if not
    /// provided:
    /// - ``NIOHTTPServerConfiguration/HTTP3/defaults``
    /// - ``NIOHTTPServerConfiguration/HTTP3/ConnectionSettings/defaults``
    /// - ``NIOHTTPServerConfiguration/HTTP3/QUICConfiguration/defaults``.
    ///
    /// - **`"protocolConfiguration"`**: HTTP/3 protocol-level settings (see ``ProtocolConfiguration/init(config:)``).
    /// - **`"connectionSettings"`**: HTTP/3 connection settings exchanged with the client (see
    ///     ``ConnectionSettings/init(config:)``).
    /// - **`"quicConfiguration"`**: QUIC transport configuration (see ``QUICConfiguration/init(config:)``).
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) throws {
        self.init(
            preferHuffmanEncoding: config.bool(forKey: "preferHuffmanEncoding", default: true),
            quicConfiguration: try .init(config: config.scoped(to: "quicConfiguration")),
            connectionSettings: .init(config: config.scoped(to: "connectionSettings"))
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3.QUICConfiguration {
    /// Initialize a QUIC transport configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `keyExchangeGroup` (string, optional, default: "x25519"): The named group to use for the TLS 1.3 key exchange
    ///   (permitted values: `"secp256"`, `"secp384"`, `"x25519"`, `"x25519MLKEM768"`).
    /// - `maxIdleTimeout` (int seconds, optional, default: 30): The idle timeout (in seconds) advertised to the client.
    /// - `initialMaxData` (int bytes, optional, default: 1 MiB): The initial value for the maximum amount of data that
    ///   can be sent on the connection.
    /// - `initialMaxStreamDataBidirectionalLocal` (int bytes, optional, default: 1 MiB): The initial flow control limit
    ///   for locally initiated bidirectional streams.
    /// - `initialMaxStreamDataBidirectionalRemote` (int bytes, optional, default: 1 MiB): The initial flow control
    ///   limit for client-initiated bidirectional streams.
    /// - `initialMaxStreamDataUnidirectional` (int bytes, optional, default: 1 MiB): The initial flow control limit for
    ///   unidirectional streams.
    /// - `initialMaxStreamsBidirectional` (int, optional, default: 100): The initial maximum number of bidirectional
    ///   streams the server is permitted to initiate.
    /// - `initialMaxStreamsUnidirectional` (int, optional, default: 100): The initial maximum number of unidirectional
    ///   streams the server is permitted to initiate.
    /// - `keepAliveInterval` (int seconds, optional, default: nil): The interval (in seconds) at which the server sends
    ///    keep-alive PING frames. When omitted, no keep-alive PINGs are sent.
    /// - `sendRetry` (bool, optional, default: false): Whether the server sends a Retry packet before accepting a new
    ///   connection.
    /// - `keyLogPath` (string, optional, default: nil): The path to the file where TLS session keys are logged in NSS
    ///    Key Log format. When omitted, keys are not logged.
    /// - `qlog` (optional, default: nil): qlog output configuration. When present, its `path`, `topic`, and
    ///   `description` are required; when omitted, qlog output is disabled.
    ///
    /// - Throws: If `keyExchangeGroup` is specified with an invalid value, or when `qlog` is partially specified.
    ///
    /// - SeeAlso: ``NIOHTTPServerConfiguration/HTTP3/QUICConfiguration``.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) throws {
        let keyExchangeGroup: KeyExchangeGroup
        if config.string(forKey: "keyExchangeGroup") == nil {
            keyExchangeGroup = .x25519
        } else {
            // If a `keyExchangeGroup` value *is* specified, it must be a permitted value. We use `requiredString` so
            // that an unrecognised value results in an error.
            keyExchangeGroup = KeyExchangeGroup(
                try config.requiredString(forKey: "keyExchangeGroup", as: KeyExchangeGroupKind.self)
            )
        }

        self.init(
            serverName: "",
            keyExchangeGroup: keyExchangeGroup,
            maxIdleTimeout: .seconds(config.int(forKey: "maxIdleTimeout", default: 30)),
            initialMaxData: config.int(forKey: "initialMaxData", default: 1024 * 1024),
            initialMaxStreamDataBidirectionalLocal: config.int(
                forKey: "initialMaxStreamDataBidirectionalLocal",
                default: 1024 * 1024
            ),
            initialMaxStreamDataBidirectionalRemote: config.int(
                forKey: "initialMaxStreamDataBidirectionalRemote",
                default: 1024 * 1024
            ),
            initialMaxStreamDataUnidirectional: config.int(
                forKey: "initialMaxStreamDataUnidirectional",
                default: 1024 * 1024
            ),
            initialMaxStreamsBidirectional: config.int(forKey: "initialMaxStreamsBidirectional", default: 100),
            initialMaxStreamsUnidirectional: config.int(forKey: "initialMaxStreamsUnidirectional", default: 100),
            keepAliveInterval: config.int(forKey: "keepAliveInterval").map { .seconds($0) },
            sendRetry: config.bool(forKey: "sendRetry", default: false),
            keyLogPath: config.string(forKey: "keyLogPath"),
            qLogConfiguration: try QLogConfiguration(config: config.scoped(to: "qlog"))
        )
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.QLogConfiguration {
    /// Initialize an optional qlog configuration from a config reader.
    ///
    /// ## Configuration keys:
    /// - `path` (string): The directory to write qlog files to.
    /// - `topic` (string): The title to use when logging.
    /// - `description` (string): The description to use when logging.
    ///
    /// - Note: If none of `path`, `topic`, or `description` are present, `nil` is returned. If *any* of them is
    ///   present, all three are required.
    ///
    /// - Throws: If some, but not all, of `path`, `topic`, and `description` are specified.
    ///
    /// - Parameter config: The configuration reader, scoped to the `qlog` key.
    fileprivate init?(config: ConfigSnapshotReader) throws {
        let path = config.string(forKey: "path")
        let topic = config.string(forKey: "topic")
        let description = config.string(forKey: "description")

        if path == nil, topic == nil, description == nil {
            return nil
        }

        self.init(
            path: try config.requiredString(forKey: "path"),
            topic: try config.requiredString(forKey: "topic"),
            description: try config.requiredString(forKey: "description")
        )
    }
}

/// The permitted string values for the `keyExchangeGroup` configuration key.
private enum KeyExchangeGroupKind: String {
    case secp256
    case secp384
    case x25519
    case x25519MLKEM768
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.KeyExchangeGroup {
    fileprivate init(_ kind: KeyExchangeGroupKind) {
        switch kind {
        case .secp256:
            self = .secp256
        case .secp384:
            self = .secp384
        case .x25519:
            self = .x25519
        case .x25519MLKEM768:
            self = .x25519MLKEM768
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3.ConnectionSettings {
    /// Initialize HTTP/3 connection settings from a config reader.
    ///
    /// ## Configuration keys:
    /// - `qpackMaximumTableCapacity` (int, optional, default: 0): The maximum capacity of the QPACK dynamic table.
    /// - `qpackBlockedStreams` (int, optional, default: 0): The maximum number of streams which may be blocked on QPACK
    ///    at any one time.
    /// - `maximumFieldSectionSize` (int, optional, default: nil): The maximum size of a field section. When omitted,
    ///    there is no field section size limit.
    ///
    /// - Note: Negative `qpackMaximumTableCapacity` and `qpackBlockedStreams` values are clamped to 0. A negative
    ///   `maximumFieldSectionSize` value is resolved to `nil`.
    ///
    /// - SeeAlso: ``NIOHTTPServerConfiguration/HTTP3/ConnectionSettings``.
    ///
    /// - Parameter config: The configuration reader.
    public init(config: ConfigSnapshotReader) {
        self.init(
            qpackMaximumTableCapacity: UInt64(clamping: config.int(forKey: "qpackMaximumTableCapacity", default: 0)),
            qpackBlockedStreams: UInt64(clamping: config.int(forKey: "qpackBlockedStreams", default: 0)),
            maximumFieldSectionSize: config.int(forKey: "maximumFieldSectionSize").flatMap { value in
                if value < 0 { return nil }
                return UInt64(value)
            }
        )
    }
}
#endif  // HTTP3 && Configuration
