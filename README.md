# Swift HTTP Server

This repository contains the Swift HTTP Server project.
It provides a low-level yet ergonomic API for handling HTTP requests and responses with full support 
for bi-directional streaming, request and response trailers, and Structured Concurrency-based 
resource management.

## 🚧 This project is a work in progress 🚧

All feedback is welcome: please open issues!

## Getting started

To get started, please refer to the project's documentation and the Example located under `Sources`.

## Package traits

This package offers additional integrations you can enable using
[package traits](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies#Packages-with-Traits).

Available traits:
- **`Configuration`** (default): Enables initializing `NIOHTTPServerConfiguration` from a `swift-configuration`
  `ConfigProvider`.
