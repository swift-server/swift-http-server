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

/// Decides when ``ConnectionLimitHandler`` may forward `read()` calls and admit accepted connections.
struct ConnectionLimitStateMachine: ~Copyable {
    /// Tracks whether a `read()` call is waiting to be forwarded.
    private enum ReadState: ~Copyable {
        /// We are not holding back a `read()` call.
        case idle(Limits)

        /// We are holding back a `read()` call until an admitted connection closes.
        case waitingForCapacity(Limits)

        /// We are holding back a `read()` call until the connection rate limiter has a token again.
        case waitingForToken(Limits)

        /// The handler was removed.
        case removed

        struct Limits: ~Copyable {
            /// The `maxConnections` limit: how many admitted connections can be open at once.
            struct OpenConnectionLimit: ~Copyable {
                let maxConnections: Int
                private var openConnections = 0

                init(maxConnections: Int) {
                    self.maxConnections = maxConnections
                }

                /// Whether another connection may be admitted.
                var hasCapacity: Bool {
                    self.openConnections < self.maxConnections
                }

                mutating func connectionOpened() {
                    self.openConnections += 1
                }

                mutating func connectionClosed() {
                    assert(self.openConnections > 0, "More connections closed than opened")
                    self.openConnections -= 1
                }
            }

            /// The `newConnectionRateLimit`: how quickly incoming connections can be accepted.
            struct RateLimit: ~Copyable {
                private var tokens: TokenBucket

                init(newConnectionRateLimit: Int) {
                    // Round up so that tokens never refill faster than the configured rate.
                    let rate = Int64(newConnectionRateLimit)
                    let refillInterval = TimeAmount.nanoseconds((1_000_000_000 + rate - 1) / rate)
                    self.tokens = TokenBucket(capacity: newConnectionRateLimit, refillInterval: refillInterval)
                }

                /// How long until another connection may be accepted, or `nil` if a connection can be accepted now.
                mutating func timeUntilNextConnection(now: NIODeadline) -> TimeAmount? {
                    self.tokens.timeUntilNextToken(now: now)
                }

                /// Takes a token for an admitted connection.
                mutating func connectionAdmitted(now: NIODeadline) {
                    self.tokens.take(now: now)
                }
            }

            var openConnectionLimit: OpenConnectionLimit?
            var rateLimit: RateLimit?

            enum ReadAction: ~Copyable {
                case waitForConnectionCapacity
                case waitForNextRateLimitToken(delay: TimeAmount)
                case forwardRead
            }

            mutating func readIfAllowed(now: NIODeadline) -> ReadAction {
                if self.openConnectionLimit?.hasCapacity == false {
                    self = .init(openConnectionLimit: self.openConnectionLimit, rateLimit: self.rateLimit)
                    // We hit the limit for active connections. Hold the `read()` call until some connections close.
                    return .waitForConnectionCapacity
                }

                if let delay = self.rateLimit?.timeUntilNextConnection(now: now) {
                    self = .init(openConnectionLimit: self.openConnectionLimit, rateLimit: self.rateLimit)
                    // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                    return .waitForNextRateLimitToken(delay: delay)
                }

                self = .init(openConnectionLimit: self.openConnectionLimit, rateLimit: self.rateLimit)
                return .forwardRead
            }
        }
    }

    private var readState: ReadState

    private init(readState: consuming ReadState) {
        self.readState = readState
    }

    /// At least one of the limits must be set.
    ///
    /// - Parameters:
    ///   - maxConnections: How many admitted connections can be open at once. `nil` means unlimited.
    ///   - newConnectionRateLimit: How quickly connections can be accepted. `nil` means unlimited.
    init(maxConnections: Int? = nil, newConnectionRateLimit: Int? = nil) {
        assert(
            maxConnections != nil || newConnectionRateLimit != nil,
            "A ConnectionLimitStateMachine needs at least one limit"
        )

        self.readState = .idle(
            .init(
                openConnectionLimit: maxConnections.map { limit in
                    .init(maxConnections: limit)
                },
                rateLimit: newConnectionRateLimit.map { limit in
                    .init(newConnectionRateLimit: limit)
                }
            )
        )
    }

    /// The action the handler should take following a `read()` call.
    enum ReadAction: ~Copyable {
        /// Forward the `read()` call.
        case forwardRead

        /// Keep the `read()` call waiting, and schedule the next-token callback which should call
        /// ``nextTokenDue(now:)`` after `delay`.
        case waitForNextToken(in: TimeAmount)

        /// Don't forward the `read()` call now.
        case doNothing
    }

    /// Determines whether the handler should forward or hold back an incoming `read()` call.
    mutating func read(now: NIODeadline) -> ReadAction {
        switch consume self.readState {
        case .idle(var limits):
            switch limits.readIfAllowed(now: now) {
            case .waitForConnectionCapacity:
                // We hit the limit for active connections. Hold the `read()` call until some connections close.
                self = .init(readState: .waitingForCapacity(limits))
                return .doNothing

            case .waitForNextRateLimitToken(let delay):
                // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                self = .init(readState: .waitingForToken(limits))
                return .waitForNextToken(in: delay)

            case .forwardRead:
                self = .init(readState: .idle(limits))
                return .forwardRead
            }

        case .waitingForCapacity(var limits):
            switch limits.readIfAllowed(now: now) {
            case .waitForConnectionCapacity:
                // We hit the limit for active connections. Hold the `read()` call until some connections close.
                self = .init(readState: .waitingForCapacity(limits))
                return .doNothing

            case .waitForNextRateLimitToken(let delay):
                // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                self = .init(readState: .waitingForToken(limits))
                return .waitForNextToken(in: delay)

            case .forwardRead:
                self = .init(readState: .idle(limits))
                return .forwardRead
            }

        case .waitingForToken(let limits):
            // The next-token callback is scheduled. Hold for now; that callback will decide what to do with the
            // `read()` call.
            self = .init(readState: .waitingForToken(limits))
            return .doNothing

        case .removed:
            self = .init(readState: .removed)
            preconditionFailure("read() called after the handler was removed")
        }
    }

    /// Informs the state machine that the handler accepted a connection.
    mutating func connectionAccepted(now: NIODeadline) {
        // We might temporarily exceed the limits here. This is because a single `read()` call can potentially lead to
        // multiple connections being accepted (depending on the `MaxMessagesPerReadOption` channel option, which
        // defaults to 4).
        //
        // For the connection rate limit, the token balance becomes negative when we exceed the limit. While the token
        // balance is negative, we artificially consume tokens (i.e. take a token and do nothing with it) until the
        // "debt" is repaid. For the active connection limit, we just go over the limit. New connections are only
        // admitted once the limit comes down.
        switch consume self.readState {
        case .idle(var limits):
            limits.rateLimit?.connectionAdmitted(now: now)
            limits.openConnectionLimit?.connectionOpened()
            self = .init(readState: .idle(limits))

        case .waitingForCapacity(var limits):
            limits.rateLimit?.connectionAdmitted(now: now)
            limits.openConnectionLimit?.connectionOpened()
            self = .init(readState: .waitingForCapacity(limits))

        case .waitingForToken(var limits):
            limits.rateLimit?.connectionAdmitted(now: now)
            limits.openConnectionLimit?.connectionOpened()
            self = .init(readState: .waitingForToken(limits))

        case .removed:
            self = .init(readState: .removed)
            preconditionFailure("connectionAccepted(now:) called after the handler was removed")
        }
    }

    /// An admitted connection closed.
    mutating func connectionClosed(now: NIODeadline) -> ReadAction {
        switch consume self.readState {
        case .idle(var limits):
            limits.openConnectionLimit?.connectionClosed()
            self = .init(readState: .idle(limits))
            return .doNothing

        case .waitingForCapacity(var limits):
            limits.openConnectionLimit?.connectionClosed()
            // We previously held back a `read()` call due to the connection limit being hit. Check if that `read()`
            // call can be forwarded now.
            switch limits.readIfAllowed(now: now) {
            case .waitForConnectionCapacity:
                // We hit the limit for active connections. Hold the `read()` call until some connections close.
                self = .init(readState: .waitingForCapacity(limits))
                return .doNothing

            case .waitForNextRateLimitToken(let delay):
                // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                self = .init(readState: .waitingForToken(limits))
                return .waitForNextToken(in: delay)

            case .forwardRead:
                self = .init(readState: .idle(limits))
                return .forwardRead
            }

        case .waitingForToken(var limits):
            limits.openConnectionLimit?.connectionClosed()
            self = .init(readState: .waitingForToken(limits))
            // The next-token callback is scheduled. That callback will decide whether we can call `read()` again.
            return .doNothing

        case .removed:
            self = .init(readState: .removed)
            return .doNothing
        }
    }

    /// The next-token callback scheduled by a ``ReadAction/waitForNextToken(in:)`` action was called.
    mutating func nextTokenDue(now: NIODeadline) -> ReadAction {
        switch consume self.readState {
        case .waitingForToken(var limits):
            // We previously held back a `read()` call due to the connection rate limit being hit. We have now waited
            // for the token refill interval, so let's check if the `read()` call can be forwarded now.
            switch limits.readIfAllowed(now: now) {
            case .waitForConnectionCapacity:
                // We hit the limit for active connections. Hold the `read()` call until some connections close.
                self = .init(readState: .waitingForCapacity(limits))
                return .doNothing

            case .waitForNextRateLimitToken(let delay):
                // We are rate limited on accepting new connections. Hold the `read()` call and try again after `delay`.
                self = .init(readState: .waitingForToken(limits))
                return .waitForNextToken(in: delay)

            case .forwardRead:
                self = .init(readState: .idle(limits))
                return .forwardRead
            }

        case .idle(let limits):
            self = .init(readState: .idle(limits))
            preconditionFailure("nextTokenDue(now:) called while no next-token callback is scheduled")

        case .waitingForCapacity(let limits):
            self = .init(readState: .waitingForCapacity(limits))
            preconditionFailure("nextTokenDue(now:) called while no next-token callback is scheduled")

        case .removed:
            self = .init(readState: .removed)
            return .doNothing
        }
    }

    /// What the handler should do once it is removed from the pipeline.
    enum HandlerRemovedAction: ~Copyable {
        /// Cancel the next-token callback, which is scheduled.
        case cancelNextTokenCallback

        /// There's nothing to clean up.
        case doNothing
    }

    /// The handler was removed from the pipeline. Nothing is forwarded or started after this.
    mutating func handlerRemoved() -> HandlerRemovedAction {
        switch consume self.readState {
        case .waitingForToken:
            self = .init(readState: .removed)
            return .cancelNextTokenCallback

        case .idle:
            self = .init(readState: .removed)
            return .doNothing

        case .waitingForCapacity:
            self = .init(readState: .removed)
            return .doNothing

        case .removed:
            self = .init(readState: .removed)
            preconditionFailure("handlerRemoved() called twice")
        }
    }
}
