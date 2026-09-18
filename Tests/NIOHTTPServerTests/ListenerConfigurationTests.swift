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

import Testing

@testable import NIOHTTPServer

@Suite
struct ListenerConfigurationTests {
    @available(anyAppleOS 26.0, *)
    @Test("transport: plaintext, versions: {HTTP/1.1} -> plaintext")
    func plaintextHTTP1_1() throws {
        let configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http1_1],
            transportSecurity: .plaintext
        )

        let listenerConfiguration = configuration.makeListenerConfiguration()

        guard case .plaintextHTTP1_1 = listenerConfiguration else {
            Issue.record("Expected .plaintextHTTP1_1 but got \(listenerConfiguration).")
            return
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "transport: TLS, versions: {HTTP/1.1 and/or HTTP/2} -> secure upgrade",
        arguments: [
            [NIOHTTPServerConfiguration.HTTPVersion.http1_1],
            [.http2],
            [.http1_1, .http2],
        ]
    )
    func tlsHTTP1_1AndOrHTTP2(
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>
    ) throws {
        let chain = try TestCA.makeSelfSignedChain()

        let configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: supportedHTTPVersions,
            transportSecurity: .tls(
                credentials: .x509(.certificates(chain: chain.chain, privateKey: chain.privateKey))
            )
        )

        let listenerConfiguration = configuration.makeListenerConfiguration()

        guard case .secureUpgrade = listenerConfiguration else {
            Issue.record("Expected .secureUpgrade but got \(listenerConfiguration).")
            return
        }
    }

    #if HTTP3
    @available(anyAppleOS 26.0, *)
    @Test("transport: TLS, versions: {HTTP/3} -> HTTP/3")
    func http3Only() throws {
        let chain = try TestCA.makeSelfSignedChain()
        let (leafPath, _, keyPath) = try chain.writeToDisk()

        let configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: [.http3],
            transportSecurity: .tls(
                credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
            )
        )

        let listenerConfiguration = configuration.makeListenerConfiguration()

        guard case .http3 = listenerConfiguration else {
            Issue.record("Expected .http3 but got \(listenerConfiguration).")
            return
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test(
        "transport: TLS, versions: {HTTP/1.1 and/or HTTP/2} + {HTTP/3} -> HTTP/3 and secure upgrade",
        arguments: [
            [NIOHTTPServerConfiguration.HTTPVersion.http1_1, .http3],
            [.http2, .http3],
            [.http1_1, .http2, .http3],
        ]
    )
    func tlsCombinationOfSecureUpgradeAndHTTP3(
        supportedHTTPVersions: Set<NIOHTTPServerConfiguration.HTTPVersion>
    ) throws {
        let chain = try TestCA.makeSelfSignedChain()
        let (leafPath, _, keyPath) = try chain.writeToDisk()

        let configuration = try NIOHTTPServerConfiguration(
            bindTarget: .hostAndPort(host: "127.0.0.1", port: 0),
            supportedHTTPVersions: supportedHTTPVersions,
            transportSecurity: .tls(
                credentials: .x509(.pemFile(certificateChainPath: leafPath, privateKeyPath: keyPath))
            )
        )

        let listenerConfiguration = configuration.makeListenerConfiguration()

        guard case .secureUpgradeAndHTTP3 = listenerConfiguration else {
            Issue.record("Expected .secureUpgradeAndHTTP3 but got \(listenerConfiguration).")
            return
        }
    }
    #endif  // HTTP3
}
