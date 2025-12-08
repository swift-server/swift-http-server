//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOCore
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOHTTPTypesHTTP2
import NIOPosix
import NIOSSL
import X509

@testable import HTTPServer

typealias ClientChannel = NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
func setUpClient(host: String, port: Int) async throws -> ClientChannel {
    try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .connect(to: try .init(ipAddress: host, port: port)) { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHTTPClientHandlers()
                try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPClientCodec())

                return try ClientChannel(wrappingChannelSynchronously: channel, configuration: .init())
            }
        }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
func setUpClientWithMTLS(
    at address: HTTPServer.SocketAddress,
    chain: ChainPrivateKeyPair,
    trustRoots: [Certificate],
    applicationProtocol: String,
) async throws -> ClientChannel {
    var clientTLSConfig = TLSConfiguration.makeClientConfiguration()
    clientTLSConfig.certificateChain = [try NIOSSLCertificateSource(chain.leaf)]
    clientTLSConfig.privateKey = .privateKey(try .init(chain.privateKey))
    clientTLSConfig.trustRoots = .certificates(try trustRoots.map { try NIOSSLCertificate($0) })
    clientTLSConfig.certificateVerification = .noHostnameVerification
    clientTLSConfig.applicationProtocols = [applicationProtocol]

    let sslContext = try NIOSSLContext(configuration: clientTLSConfig)

    let clientNegotiatedChannel = try await ClientBootstrap(group: .singletonMultiThreadedEventLoopGroup)
        .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
        .connect(to: try .init(ipAddress: address.host, port: address.port)) { channel in
            channel.eventLoop.makeCompletedFuture {
                let sslHandler = try NIOSSLClientHandler(context: sslContext, serverHostname: nil)
                try channel.pipeline.syncOperations.addHandler(sslHandler)
            }.flatMap {
                channel.configureHTTP2AsyncSecureUpgrade(
                    http1ConnectionInitializer: { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHTTPClientHandlers()
                            try channel.pipeline.syncOperations.addHandlers(HTTP1ToHTTPClientCodec())

                            return try ClientChannel(wrappingChannelSynchronously: channel, configuration: .init())
                        }
                    },
                    http2ConnectionInitializer: { channel in
                        channel.configureAsyncHTTP2Pipeline(mode: .client) { $0.eventLoop.makeSucceededFuture($0) }
                    }
                )
            }
        }.get()

    switch clientNegotiatedChannel {
    case .http1_1(let http1Channel):
        precondition(applicationProtocol == "http/1.1", "Unexpectedly established a HTTP 1.1 channel")
        return http1Channel

    case .http2(let http2Channel):
        precondition(applicationProtocol == "h2", "Unexpectedly established a HTTP 2 channel")
        return try await http2Channel.openStream { channel in
            channel.eventLoop.makeCompletedFuture {
                try channel.pipeline.syncOperations.addHandler(HTTP2FramePayloadToHTTPClientCodec())
                return try ClientChannel(wrappingChannelSynchronously: channel, configuration: .init())
            }
        }
    }
}
