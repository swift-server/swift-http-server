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
import NIOQUIC
import Testing

@testable import NIOHTTPServer

@Suite
struct HTTP3ConfigurationTests {
    @Test("HTTP/3 default configuration uses the defaults of the sub-components")
    @available(anyAppleOS 27.0, *)
    func http3DefaultConfiguration() {
        let config = NIOHTTPServerConfiguration.HTTP3.defaults
        #expect(config.quicConfiguration == .defaults)
        #expect(config.connectionSettings == .defaults)
    }

    @Test("HTTP/3 configuration with custom values")
    @available(anyAppleOS 27.0, *)
    func http3ConfigurationCustomValues() {
        var connectionSettings = NIOHTTPServerConfiguration.HTTP3.ConnectionSettings.defaults
        connectionSettings.qpackMaximumTableCapacity = 4096
        connectionSettings.qpackBlockedStreams = 16
        connectionSettings.maximumFieldSectionSize = 8192

        var quic = NIOHTTPServerConfiguration.HTTP3.QUICConfiguration.defaults
        quic.keepAliveInterval = .seconds(10)
        quic.sendRetry = true

        let config = NIOHTTPServerConfiguration.HTTP3(
            preferHuffmanEncoding: false,
            quicConfiguration: quic,
            connectionSettings: connectionSettings
        )

        #expect(config.preferHuffmanEncoding == false)
        #expect(config.connectionSettings.qpackMaximumTableCapacity == 4096)
        #expect(config.connectionSettings.qpackBlockedStreams == 16)
        #expect(config.connectionSettings.maximumFieldSectionSize == 8192)
        #expect(config.quicConfiguration.keepAliveInterval == .seconds(10))
        #expect(config.quicConfiguration.sendRetry == true)
    }

    @Suite
    struct AuthenticationConfigurationTests {
        @Test("In-memory TLS credentials are rejected")
        @available(anyAppleOS 27.0, *)
        func inMemoryCredentialsRejected() throws {
            let chain = try TestCA.makeSelfSignedChain()
            #expect(throws: NIOHTTPServerConfigurationError.onlyPEMFileX509CredentialsCurrentlySupportedOverHTTP3) {
                _ = try NIOQUIC.AuthenticationConfiguration(
                    .x509(.certificates(chain: chain.chain, privateKey: chain.privateKey))
                )
            }
        }

        @Test("PEM-file TLS credentials are accepted")
        @available(anyAppleOS 27.0, *)
        func pemFileCredentialsAccepted() {
            #expect(throws: Never.self) {
                _ = try NIOQUIC.AuthenticationConfiguration(
                    .x509(.pemFile(certificateChainPath: "/cert.pem", privateKeyPath: "/key.pem"))
                )
            }
        }
    }

    @Test("Unix domain socket bind target is rejected for HTTP/3")
    @available(anyAppleOS 27.0, *)
    func unixDomainSocketRejectedForHTTP3() {
        #expect(throws: NIOHTTPServerConfigurationError.unixDomainSocketNotSupportedOverHTTP3) {
            _ = try NIOHTTPServerConfiguration(
                bindTarget: .unixDomainSocket(path: "/tmp/http3.sock"),
                supportedHTTPVersions: [.http3(config: .defaults)],
                transportSecurity: .tls(
                    credentials: .x509(.pemFile(certificateChainPath: "/cert.pem", privateKeyPath: "/key.pem"))
                )
            )
        }
    }

    // The setters below must enforce the same rule as `init`. Each test first builds the starting configuration
    // outside the exit test, so the exit test can only pass because of the setter, not because the starting
    // configuration was invalid.

    @Test("Adding HTTP/3 to a configuration with a unix domain socket bind target is a precondition failure")
    @available(anyAppleOS 27.0, *)
    func addingHTTP3ToUnixDomainSocketConfigurationFails() async throws {
        _ = try TestHelpers.makeTLSServerConfiguration(
            supportedHTTPVersions: [.http1_1, .http2],
            bindTargetsOverride: [.unixDomainSocket(path: "/tmp/http3-setter.sock")]
        )

        await #expect(processExitsWith: .failure) {
            var (configuration, _) = try TestHelpers.makeTLSServerConfiguration(
                supportedHTTPVersions: [.http1_1, .http2],
                bindTargetsOverride: [.unixDomainSocket(path: "/tmp/http3-setter.sock")]
            )
            configuration.supportedHTTPVersions.insert(.http3(config: .defaults))
        }
    }

    @Test("Adding a unix domain socket bind target to an HTTP/3 configuration is a precondition failure")
    @available(anyAppleOS 27.0, *)
    func addingUnixDomainSocketToHTTP3ConfigurationFails() async throws {
        _ = try TestHelpers.makeTLSServerConfiguration(supportedHTTPVersions: [.http3(config: .defaults)])

        await #expect(processExitsWith: .failure) {
            var (configuration, _) = try TestHelpers.makeTLSServerConfiguration(
                supportedHTTPVersions: [.http3(config: .defaults)]
            )
            configuration.bindTargets = [.unixDomainSocket(path: "/tmp/http3-setter.sock")]
        }
    }
}
#endif  // HTTP3
