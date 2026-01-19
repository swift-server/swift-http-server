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

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, visionOS 26.0, *)
extension InlineArray where Element: ~Copyable {
    package static func one(value: consuming Element) -> InlineArray<1, Element> {
        InlineArray<1, Element>(first: value) { _ in fatalError() }
    }

    package static func zero(of elementType: Element.Type = Element.self) -> InlineArray<0, Element> {
        InlineArray<0, Element> { _ in }
    }
}
