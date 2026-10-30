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

struct TokenBucketTests {
    @Test func burstUpToCapacityIsAllowedInstantly() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        for _ in 0..<2 {
            #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == nil)
            bucket.take(now: .uptimeNanoseconds(0))
        }
    }

    @Test func emptyBucketHasNoToken() {
        // Create a bucket with capacity 2, and empty out both tokens.
        var bucket = TokenBucket(capacity: 2, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))
        // Now there must be no tokens left.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .milliseconds(500))
    }

    @Test func tokensRefillProportionallyToElapsedTime() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))

        // One refill interval (500ms) later, exactly one token is back.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(500_000_000)) == nil)
        bucket.take(now: .uptimeNanoseconds(500_000_000))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(500_000_000)) == .milliseconds(500))
    }

    @Test func refillNeverExceedsCapacity() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))

        // An hour of idle time shouldn't bank more than the 2-token capacity.
        bucket.take(now: .uptimeNanoseconds(3_600_000_000_000))
        bucket.take(now: .uptimeNanoseconds(3_600_000_000_000))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(3_600_000_000_000)) == .milliseconds(500))
    }

    @Test func capacityAndRefillIntervalAreIndependent() {
        var bucket = TokenBucket(capacity: 5, refillInterval: .seconds(1), now: .uptimeNanoseconds(0))
        for _ in 0..<5 {
            bucket.take(now: .uptimeNanoseconds(0))
        }
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .seconds(1))

        // One second later, only 1 token (one refill interval) has come back, not 5.
        bucket.take(now: .uptimeNanoseconds(1_000_000_000))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(1_000_000_000)) == .seconds(1))
    }

    @Test func partialIntervalsAccumulateAcrossCalls() {
        // Polling more often than the refill interval (500ms) must not lose progress: each individual call sees less
        // than one interval's worth of elapsed time, but a token should still appear once their sum crosses one
        // interval.
        var bucket = TokenBucket(capacity: 1, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))

        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(200_000_000)) == .milliseconds(300))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(400_000_000)) == .milliseconds(100))
        // After we cross 500ms, there must be a token available.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(501_000_000)) == nil)
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(600_000_000)) == nil)
    }

    @Test func noTokenIsGrantedOneNanosecondShortOfAnInterval() {
        var bucket = TokenBucket(capacity: 1, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))

        // One nanosecond short of the 500ms interval: integer division must truncate, not round.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(499_999_999)) == .nanoseconds(1))

        // The previous call gained zero tokens, so it must not have advanced the refill clock either: elapsed time is
        // still measured from t=0, and exactly 500ms have now passed.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(500_000_000)) == nil)
    }

    @Test func timeSpentAtCapacityDoesNotCountTowardsTheNextToken() {
        // Refill progress made while the bucket is full must be discarded,
        // not banked towards the token after the next consumption.
        var bucket = TokenBucket(capacity: 1, refillInterval: .seconds(1), now: .uptimeNanoseconds(0))

        // The initial token is held until t=999ms.
        bucket.take(now: .uptimeNanoseconds(999_000_000))
        // Wait 1ms.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(1_000_000_000)) == .milliseconds(999))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(1_999_000_000)) == nil)
    }

    @Test func timeSpentAtCapacityAfterRefillingDoesNotCountTowardsTheNextToken() {
        // Like `timeSpentAtCapacityDoesNotCountTowardsTheNextToken`, but the bucket reaches
        // capacity by refilling instead of starting full.
        var bucket = TokenBucket(capacity: 1, refillInterval: .seconds(1), now: .uptimeNanoseconds(0))
        bucket.take(now: .uptimeNanoseconds(0))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .seconds(1))

        // The bucket is full again from t=1000ms.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(1_000_000_000)) == nil)

        // Wait 999ms before consuming a token. During this time, there should be no refill progress since the bucket is
        // at capacity.
        bucket.take(now: .uptimeNanoseconds(1_999_000_000))
        // The bucket should now be empty.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(1_999_000_000)) == .seconds(1))
    }

    @Test func tokensTakenFromAnEmptyBucketAreRefilledFirst() {
        var bucket = TokenBucket(capacity: 2, refillInterval: .milliseconds(500), now: .uptimeNanoseconds(0))

        // First consume the available tokens.
        bucket.take(now: .uptimeNanoseconds(0))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == nil)

        bucket.take(now: .uptimeNanoseconds(0))
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .milliseconds(500))

        // Now go into debt.
        bucket.take(now: .uptimeNanoseconds(0))
        // The next token will be available after 2 `refreshInterval`s (we need to pay for the one we just borrowed,
        // and for the next token itself).
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .milliseconds(1000))

        // Go into more debt.
        bucket.take(now: .uptimeNanoseconds(0))
        // Now we need to wait 3 `refreshInterval`s for the next token to be available.
        #expect(bucket.timeUntilNextToken(now: .uptimeNanoseconds(0)) == .milliseconds(1500))
    }
}
