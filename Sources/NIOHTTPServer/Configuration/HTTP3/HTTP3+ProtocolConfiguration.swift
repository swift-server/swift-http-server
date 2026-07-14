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

import NIOHTTP3

@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3 {
    /// HTTP/3 protocol-level configuration.
    public struct ProtocolConfiguration: Sendable, Hashable {
        /// If true, Huffman encoding will be used where applicable, e.g. for header field sections.
        ///
        /// - Note: Huffman encoding will not be used if it would result in a larger payload than not using it, even if
        ///   this property is true.
        public var preferHuffmanEncoding: Bool

        /// The default HTTP/3 protocol configuration.
        public static var defaults: Self {
            Self(preferHuffmanEncoding: true)
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTP3.HTTP3ServerConfiguration {
    init(_ configuration: NIOHTTPServerConfiguration.HTTP3.ProtocolConfiguration) {
        self = .defaults
        self.preferHuffmanEncoding = configuration.preferHuffmanEncoding
    }
}
