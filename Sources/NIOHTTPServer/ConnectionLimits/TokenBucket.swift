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

/// A token bucket: holds at most `capacity` tokens, refilled continuously at one token every
/// `refillInterval`.
///
/// A token can be taken even when the bucket is empty. The bucket then holds a negative number of tokens.
struct TokenBucket {
    /// The maximum number of tokens the bucket can hold.
    private let capacity: Int
    /// How long it takes to generate one token.
    private let refillInterval: TimeAmount
    private var availableTokens: Int
    private var lastRefill: NIODeadline

    /// - Parameters:
    ///   - capacity: The maximum number of tokens the bucket can hold. Must not be negative. A bucket
    ///     without capacity never grants a token.
    ///   - refillInterval: How long it takes to generate one token. Must be positive.
    init(capacity: Int, refillInterval: TimeAmount, now: NIODeadline = .now()) {
        precondition(capacity >= 0, "capacity must not be negative")
        precondition(refillInterval.nanoseconds > 0, "refillInterval must be positive")
        self.capacity = capacity
        self.refillInterval = refillInterval
        self.availableTokens = capacity
        self.lastRefill = now
    }

    /// How long until a token becomes available, or `nil` if there are already tokens available in the bucket.
    mutating func timeUntilNextToken(now: NIODeadline = .now()) -> TimeAmount? {
        self.refill(now: now)

        if self.availableTokens >= 1 {
            return nil
        }

        let debt = -self.availableTokens

        // The bucket has to refill its debt, and then one more token.
        let tokensNeeded = Int64(debt + 1)
        let timeSinceLastRefill = now - self.lastRefill
        return .nanoseconds(tokensNeeded * self.refillInterval.nanoseconds) - timeSinceLastRefill
    }

    /// Takes one token, even if no tokens are available.
    mutating func take(now: NIODeadline = .now()) {
        self.refill(now: now)
        self.availableTokens -= 1
    }

    private mutating func refill(now: NIODeadline) {
        let elapsed = now - self.lastRefill
        let refillIntervalNanoseconds = self.refillInterval.nanoseconds
        let tokensGained = max(0, Int(elapsed.nanoseconds / refillIntervalNanoseconds))
        self.availableTokens = min(self.capacity, self.availableTokens + tokensGained)
        if self.availableTokens == self.capacity {
            // A full bucket discards partial refill progress, so time spent full doesn't count
            // towards the next token.
            self.lastRefill = now
        } else {
            self.lastRefill = self.lastRefill + .nanoseconds(Int64(tokensGained) * refillIntervalNanoseconds)
        }
    }
}

@available(*, unavailable)
extension TokenBucket: Sendable {}
