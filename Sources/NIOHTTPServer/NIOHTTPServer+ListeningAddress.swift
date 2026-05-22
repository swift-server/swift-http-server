//===----------------------------------------------------------------------===//
//
// This source file is part of the Swift HTTP Server open source project
//
// Copyright (c) 2025 Apple Inc. and the Swift HTTP Server project authors
// Licensed under Apache License v2.0
//
// See LICENSE.txt for license information
// See CONTRIBUTORS.txt for the list of Swift HTTP Server project authors
//
// SPDX-License-Identifier: Apache-2.0
//
//===----------------------------------------------------------------------===//

import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

enum ListeningAddressError: CustomStringConvertible, Error {
    case addressOrPortNotAvailable
    case unsupportedAddressType
    case serverClosed

    var description: String {
        switch self {
        case .addressOrPortNotAvailable:
            return "Unable to retrieve the bound address or port from the underlying socket"
        case .unsupportedAddressType:
            return "Unsupported address type: only IPv4 and IPv6 are supported"
        case .serverClosed:
            return """
                There is no listening address bound for this server: there may have been an error which caused the server to close, or it may have shut down.
                """
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    func addressesBound(_ addresses: [NIOCore.SocketAddress?]) throws {
        switch self.listeningAddressState.withLockedValue({ $0.addressesBound(addresses) }) {
        case .succeedPromise(let promise, let boundAddresses):
            promise.succeed(boundAddresses)
        case .failPromise(let promise, let error):
            promise.fail(error)
        }
    }

    /// The addresses the server is listening on.
    ///
    /// This property returns one ``SocketAddress`` per ``NIOHTTPServerConfiguration/bindTargets`` entry.
    /// It suspends until **all** bind targets have been successfully bound. If any single bind fails, no addresses are returned:
    /// the server treats its listening addresses as an all-or-nothing unit. See ``serve(handler:)`` for the full semantics.
    ///
    /// - Throws: An error will be thrown if the addresses could not be bound or are not bound any longer because the
    ///   server isn't listening anymore (for example, after ``serve(handler:)`` has returned).
    public var listeningAddresses: [SocketAddress] {
        get async throws {
            try await self.listeningAddressState
                .withLockedValue { try $0.listeningAddressesFuture }
                .get()
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer {
    enum State {
        case idle(EventLoopPromise<[SocketAddress]>)
        case listening(EventLoopFuture<[SocketAddress]>)
        case closedOrInvalidAddress(ListeningAddressError)

        var listeningAddressesFuture: EventLoopFuture<[SocketAddress]> {
            get throws {
                switch self {
                case .idle(let eventLoopPromise):
                    return eventLoopPromise.futureResult
                case .listening(let eventLoopFuture):
                    return eventLoopFuture
                case .closedOrInvalidAddress(let error):
                    throw error
                }
            }
        }

        enum OnBound {
            case succeedPromise(_ promise: EventLoopPromise<[SocketAddress]>, addresses: [SocketAddress])
            case failPromise(_ promise: EventLoopPromise<[SocketAddress]>, error: ListeningAddressError)
        }

        mutating func addressesBound(_ addresses: [NIOCore.SocketAddress?]) -> OnBound {
            switch self {
            case .idle(let listeningAddressPromise):
                var socketAddresses = [SocketAddress]()
                socketAddresses.reserveCapacity(addresses.count)
                do throws(ListeningAddressError) {
                    for address in addresses {
                        try socketAddresses.append(SocketAddress(address))
                    }
                    self = .listening(listeningAddressPromise.futureResult)
                    return .succeedPromise(listeningAddressPromise, addresses: socketAddresses)
                } catch {
                    self = .closedOrInvalidAddress(error)
                    return .failPromise(listeningAddressPromise, error: error)
                }

            case .listening, .closedOrInvalidAddress:
                fatalError("Invalid state: addressesBound should only be called once and when in idle state")
            }
        }

        enum OnClose {
            case failPromise(_ promise: EventLoopPromise<[SocketAddress]>, error: ListeningAddressError)
            case doNothing
        }

        mutating func close() -> OnClose {
            switch self {
            case .idle(let listeningAddressPromise):
                self = .closedOrInvalidAddress(.serverClosed)
                return .failPromise(listeningAddressPromise, error: .serverClosed)

            case .listening:
                self = .closedOrInvalidAddress(.serverClosed)
                return .doNothing

            case .closedOrInvalidAddress:
                return .doNothing
            }
        }
    }
}

@available(anyAppleOS 26.0, *)
extension NIOHTTPServer.SocketAddress {
    fileprivate init(_ address: NIOCore.SocketAddress?) throws(ListeningAddressError) {
        guard let address, let port = address.port else {
            throw ListeningAddressError.addressOrPortNotAvailable
        }

        switch address {
        case .v4(let ipv4Address):
            self.init(base: .ipv4(.init(host: ipv4Address.host, port: port)))
        case .v6(let ipv6Address):
            self.init(base: .ipv6(.init(host: ipv6Address.host, port: port)))
        case .unixDomainSocket:
            throw ListeningAddressError.unsupportedAddressType
        }
    }
}
