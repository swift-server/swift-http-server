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

#if UnstableWebTransport

import HTTP3

@available(anyAppleOS 27, *)
extension HTTP3Setting.Identifier {
    /// Corresponds to `SETTINGS_WT_ENABLED`.
    ///
    /// The default value is zero.
    ///
    /// See [draft-ietf-webtrans-http3-16 § 9.2](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
    static var webTransportEnabled: HTTP3Setting.Identifier {
        HTTP3Setting.Identifier(extensionSetting: 0x2c7c_f000)!
    }

    /// Corresponds to `SETTINGS_WT_INITIAL_MAX_STREAMS_UNI`.
    ///
    /// The default value is zero.
    ///
    /// See [draft-ietf-webtrans-http3-16 § 9.2](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
    static var webTransportInitialMaximumStreamsUnidirectional: HTTP3Setting.Identifier {
        HTTP3Setting.Identifier(extensionSetting: 0x2b64)!
    }

    /// Corresponds to `SETTINGS_WT_INITIAL_MAX_STREAMS_BIDI`.
    ///
    /// The default value is zero.
    ///
    /// See [draft-ietf-webtrans-http3-16 § 9.2](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
    static var webTransportInitialMaximumStreamsBidirectional: HTTP3Setting.Identifier {
        HTTP3Setting.Identifier(extensionSetting: 0x2b65)!
    }

    /// Corresponds to `SETTINGS_WT_INITIAL_MAX_DATA`.
    ///
    /// The default value is zero.
    ///
    /// See [draft-ietf-webtrans-http3-16 § 9.2](https://datatracker.ietf.org/doc/draft-ietf-webtrans-http3/)
    static var webTransportInitialMaximumData: HTTP3Setting.Identifier {
        HTTP3Setting.Identifier(extensionSetting: 0x2b61)!
    }

    static let flowControlHTTP3Settings: [HTTP3Setting.Identifier] = [
        .webTransportInitialMaximumStreamsUnidirectional,
        .webTransportInitialMaximumStreamsBidirectional,
        .webTransportInitialMaximumData,
    ]
}

@available(anyAppleOS 27, *)
extension HTTP3Settings {
    /// Whether the peer declared its intent to use WebTransport Flow Control,
    /// by sending any of the `SETTINGS_WT_INITIAL_MAX_*` settings with a value other than zero.
    var enablesWebTransportFlowControl: Bool {
        self.other.contains {
            HTTP3Setting.Identifier.flowControlHTTP3Settings.contains($0.identifier) && $0.value != 0
        }
    }
}

#endif
