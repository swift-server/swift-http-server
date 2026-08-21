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

#if HTTP3 && UnstableHTTPDatagrams
@available(anyAppleOS 26.0, *)
extension NIOHTTPServerConfiguration.HTTP3 {
    public struct DatagramConfiguration: Sendable, Hashable {
        /// The maximum datagram frame size in bytes.
        public var maxDatagramFrameSize: Int {
            didSet {
                self.validateMaxDatagramFrameSize()
            }
        }

        private func validateMaxDatagramFrameSize() {
            precondition(
                self.maxDatagramFrameSize != 0,
                "When maxDatagramFrameSize == 0, support for receiving HTTP/3 datagrams is disabled. Set `datagramConfiguration` to `nil` if you do not want to receive datagrams."
            )
        }

        /// The maximum number of inbound HTTP/3 datagrams that will be buffered for each stream.
        public var maxBufferedDatagrams: Int

        init(maxDatagramFrameSize: Int, maxBufferedDatagrams: Int) {
            self.maxDatagramFrameSize = maxDatagramFrameSize
            self.maxBufferedDatagrams = maxBufferedDatagrams

            self.validateMaxDatagramFrameSize()
        }

        /// The default HTTP/3 datagram configuration. Uses the following default values:
        ///
        /// - `maxDatagramFrameSize`: 65535
        /// - `maxBufferedDatagrams`: 16
        public static var defaults: Self {
            Self(maxDatagramFrameSize: 65535, maxBufferedDatagrams: 16)
        }
    }
}
#endif  // HTTP3 && UnstableHTTPDatagrams
