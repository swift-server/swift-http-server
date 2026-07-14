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

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3 {
    /// HTTP/3 connection settings sent to the peer during connection establishment.
    public struct ConnectionSettings: Sendable, Hashable {
        /// The maximum capacity of the QPACK dynamic table. The default value is 0.
        ///
        /// - SeeAlso: https://www.rfc-editor.org/rfc/rfc9204.html#section-5-2.2.1. Corresponds to
        ///   `SETTINGS_QPACK_MAX_TABLE_CAPACITY`.
        public var qpackMaximumTableCapacity: UInt64

        /// The maximum number of streams which may be blocked on QPACK at any one time. The default value is 0.
        ///
        /// - SeeAlso: https://www.rfc-editor.org/rfc/rfc9204.html#section-5-2.4.1. Corresponds to
        ///   `SETTINGS_QPACK_BLOCKED_STREAMS`.
        public var qpackBlockedStreams: UInt64

        /// The maximum size of a field section. The default value is `nil`, which is interpreted as there being no
        /// field section size limit.
        ///
        /// - SeeAlso: https://www.rfc-editor.org/rfc/rfc9114.html#section-7.2.4.1-2.2.1. Corresponds to
        ///   `SETTINGS_MAX_FIELD_SECTION_SIZE`.
        public var maximumFieldSectionSize: UInt64?

        /// The default configuration.
        public static var defaults: Self {
            Self(
                qpackMaximumTableCapacity: 0,
                qpackBlockedStreams: 0,
                maximumFieldSectionSize: nil
            )
        }
    }
}

@available(anyAppleOS 26.0, *)
extension HTTP3.HTTP3Settings {
    init(_ configuration: NIOHTTPServerConfiguration.HTTP3.ConnectionSettings) {
        self.init(
            qpackMaximumTableCapacity: configuration.qpackMaximumTableCapacity,
            qpackBlockedStreams: configuration.qpackBlockedStreams,
            maximumFieldSectionSize: configuration.maximumFieldSectionSize
        )
    }
}
