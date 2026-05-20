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

#if Configuration

/// A configuration error arising from an invalid ``NIOHTTPServerConfiguration`` specified via `swift-configuration`.
enum NIOHTTPServerSwiftConfigurationError: Error, CustomStringConvertible {
    case customVerificationCallbackAndTrustRootsProvided
    case customVerificationCallbackProvidedWhenNotUsingMTLS
    case trustRootsSourceAndVerificationCallbackMismatch
    case singularAndPluralBindTargetsProvided
    case bindTargetsHostsAndPortsLengthMismatch

    var description: String {
        switch self {
        case .customVerificationCallbackAndTrustRootsProvided:
            "Invalid configuration: both a custom certificate verification callback and a set of trust roots were provided. When a custom verification callback is provided, trust must be established directly within the callback."

        case .customVerificationCallbackProvidedWhenNotUsingMTLS:
            "Invalid configuration: a custom certificate verification callback was provided despite the server not being configured for mTLS."

        case .trustRootsSourceAndVerificationCallbackMismatch:
            "Invalid configuration: there is a mismatch between the trustRootsSource key and the provided customCertificateVerificationCallback."

        case .singularAndPluralBindTargetsProvided:
            "Invalid configuration: both the singular 'bindTarget' scope and the plural 'bindTargets' scope were provided. Use only one."

        case .bindTargetsHostsAndPortsLengthMismatch:
            "Invalid configuration: 'bindTargets.hosts' and 'bindTargets.ports' must have the same number of elements."
        }
    }
}

#endif  // Configuration
