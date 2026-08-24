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

import NIOCore
import Testing

@testable import NIOHTTPServer

@Suite
struct SocketAddressTests {
    @available(anyAppleOS 26.0, *)
    @Test("A nil NIO address throws addressNotAvailable")
    func testNilAddressThrows() throws {
        #expect(throws: ListeningAddressError.addressNotAvailable) {
            _ = try NIOHTTPServer.SocketAddress(nil as NIOCore.SocketAddress?)
        }
    }

    @available(anyAppleOS 26.0, *)
    @Test("An IPv4 NIO address maps to the ipv4 base")
    func testIPv4Address() throws {
        // `makeAddressResolvingHost` populates the address' `host` field the way a real bound
        // `localAddress` does; `SocketAddress(ipAddress:port:)` would leave `host` empty.
        let nioAddress = try NIOCore.SocketAddress.makeAddressResolvingHost("127.0.0.1", port: 8080)
        let address = try NIOHTTPServer.SocketAddress(nioAddress)

        let ipv4 = try #require(address.ipv4)
        #expect(ipv4.host == "127.0.0.1")
        #expect(ipv4.port == 8080)

        // Convenience accessors should agree with the concrete IPv4 value.
        #expect(address.host == "127.0.0.1")
        #expect(address.port == 8080)

        // It must not masquerade as any other address kind.
        #expect(address.ipv6 == nil)
        #expect(address.unixDomainSocketPath == nil)
    }

    @available(anyAppleOS 26.0, *)
    @Test("An IPv6 NIO address maps to the ipv6 base")
    func testIPv6Address() throws {
        let nioAddress = try NIOCore.SocketAddress.makeAddressResolvingHost("::1", port: 9090)
        let address = try NIOHTTPServer.SocketAddress(nioAddress)

        let ipv6 = try #require(address.ipv6)
        #expect(ipv6.host == "::1")
        #expect(ipv6.port == 9090)

        #expect(address.host == "::1")
        #expect(address.port == 9090)

        #expect(address.ipv4 == nil)
        #expect(address.unixDomainSocketPath == nil)
    }

    @available(anyAppleOS 26.0, *)
    @Test("A unix domain socket NIO address maps to the unixDomainSocket base")
    func testUnixDomainSocketAddress() throws {
        let path = "/tmp/nio-http-server-socket-address-test.sock"
        let nioAddress = try NIOCore.SocketAddress(unixDomainSocketPath: path)
        let address = try NIOHTTPServer.SocketAddress(nioAddress)

        #expect(address.unixDomainSocketPath == path)

        // A UDS address exposes neither host nor port.
        #expect(address.host == nil)
        #expect(address.port == nil)
        #expect(address.ipv4 == nil)
        #expect(address.ipv6 == nil)
    }
}
