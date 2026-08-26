# Configuring the server with swift-configuration

Initialize ``NIOHTTPServerConfiguration`` from a configuration source using [`swift-configuration`](https://github.com/apple/swift-configuration).

## Overview

``NIOHTTPServerConfiguration`` can be initialized from a `ConfigReader` provided by
[`swift-configuration`](https://github.com/apple/swift-configuration). This lets you load server settings from
environment variables, JSON files, or other `swift-configuration` providers.

This functionality requires the `Configuration` package trait, which is enabled by default.

### Basic usage

```swift
import Configuration
import NIOHTTPServer

// Create a configuration reader from one or more providers.
let config = ConfigReader(
    providers: [
        EnvironmentVariablesProvider(),
        try FileProvider(format: .json, filePath: "config.json"),
    ]
)

let serverConfiguration = try NIOHTTPServerConfiguration(config: config)
```

### Configuration key reference

``NIOHTTPServerConfiguration`` is comprised of several components. Provide the configuration for each component under
its respective key prefix.

> Important: Exactly one of `bindTarget` (singular, for a single address) or `bindTargets` (plural, for multiple
> addresses) must be provided. Providing both results in an error.

> Important: HTTP/2 and HTTP/3 cannot be served over plaintext. If `"http2"` or `"http3"` is included in
> `http.versions`, the transport security must be set to `"tls"` or `"mTLS"`. Additionally, HTTP/3 requires PEM file
> credentials (`credentialSource: "file"` without a `refreshInterval`) with `transportSecurity.mode` set to `"tls"`.
> Inline (in-memory) credentials, reloading credentials, and mTLS are currently not supported over HTTP/3.

| Prefix                              | Configuration Key                         | Type              | Required/Optional                                                                                                             | Default        |
|-------------------------------------|-------------------------------------------|-------------------|-------------------------------------------------------------------------------------------------------------------------------|----------------|
| `bindTarget`                        | `host`                                    | `string`          | Required when binding to a single address (mutually exclusive with `bindTargets`)                                             | -              |
|                                     | `port`                                    | `int`             | Required when binding to a single address (mutually exclusive with `bindTargets`)                                             | -              |
| `bindTargets`                       | `hosts`                                   | `string array`    | Required when binding to multiple addresses (mutually exclusive with `bindTarget`); must match length of `ports`              | -              |
|                                     | `ports`                                   | `int array`       | Required when binding to multiple addresses (mutually exclusive with `bindTarget`); must match length of `hosts`              | -              |
| `http`                              | `versions`                                | `string array`    | Required (permitted values: `"http1_1"`, `"http2"`, `"http3"`)                                                                | -              |
| `http.http2`                        | `maxFrameSize`                            | `int` (bytes)     | Optional                                                                                                                      | 2^14           |
|                                     | `targetWindowSize`                        | `int` (bytes)     | Optional                                                                                                                      | 2^16-1         |
|                                     | `maxConcurrentStreams`                    | `int`             | Optional                                                                                                                      | 100            |
| `http.http2.gracefulShutdown`       | `maximumDuration`                         | `int` (seconds)   | Optional                                                                                                                      | nil            |
| `http.http3`                        | `preferHuffmanEncoding`                   | `bool`            | Optional                                                                                                                      | true           |
| `http.http3.connectionSettings`     | `qpackMaximumTableCapacity`               | `int`             | Optional                                                                                                                      | 0              |
|                                     | `qpackBlockedStreams`                     | `int`             | Optional                                                                                                                      | 0              |
|                                     | `maximumFieldSectionSize`                 | `int`             | Optional                                                                                                                      | nil (no limit) |
| `http.http3.quicConfiguration`      | `keyExchangeGroup`                        | `string`          | Optional (permitted values: `"secp256"`, `"secp384"`, `"x25519"`, `"x25519MLKEM768"`)                                         | x25519         |
|                                     | `maxIdleTimeout`                          | `int` (seconds)   | Optional                                                                                                                      | 30             |
|                                     | `initialMaxData`                          | `int` (bytes)     | Optional                                                                                                                      | 2^20 (1 MiB)   |
|                                     | `initialMaxStreamDataBidirectionalLocal`  | `int` (bytes)     | Optional                                                                                                                      | 2^20 (1 MiB)   |
|                                     | `initialMaxStreamDataBidirectionalRemote` | `int` (bytes)     | Optional                                                                                                                      | 2^20 (1 MiB)   |
|                                     | `initialMaxStreamDataUnidirectional`      | `int` (bytes)     | Optional                                                                                                                      | 2^20 (1 MiB)   |
|                                     | `initialMaxStreamsBidirectional`          | `int`             | Optional                                                                                                                      | 100            |
|                                     | `initialMaxStreamsUnidirectional`         | `int`             | Optional                                                                                                                      | 100            |
|                                     | `keepAliveInterval`                       | `int` (seconds)   | Optional                                                                                                                      | nil (disabled) |
|                                     | `sendRetry`                               | `bool`            | Optional                                                                                                                      | false          |
|                                     | `keyLogPath`                              | `string`          | Optional                                                                                                                      | nil            |
| `http.http3.quicConfiguration.qlog` | `path`                                    | `string`          | Optional                                                                                                                      | nil            |
|                                     | `topic`                                   | `string`          | Optional                                                                                                                      | nil            |
|                                     | `description`                             | `string`          | Optional                                                                                                                      | nil            |
| `http.http3.datagramConfiguration`  | `datagramsEnabled`                        | `bool`            | Optional                                                                                                                      | true           |
|                                     | `maxDatagramFrameSize`                    | `int` (bytes)     | Optional                                                                                                                      | 65535          |
|                                     | `maxBufferedDatagramBytes`                | `int` (bytes)     | Optional                                                                                                                      | 16384          |
|                                     | `maxBufferedStreamDatagrams`              | `int`             | Optional                                                                                                                      | 16             |
| `transportSecurity`                 | `mode`                                    | `string`          | Required (permitted values: `"plaintext"`, `"tls"`, `"mTLS"`)                                                                 | -              |
|                                     | `credentialSource`                        | `string`          | Required for `"tls"` and `"mTLS"` (permitted values: `"inline"`, `"file"`, `"rawPublicKey"`)                                  | -              |
|                                     | `certificateChainPEMString`               | `string`          | Required when `credentialSource` is "inline"`                                                                                 | -              |
|                                     | `privateKeyPEMString`                     | `string` (secret) | Required when `credentialSource` is "inline"`                                                                                 | -              |
|                                     | `certificateChainPEMPath`                 | `string`          | Required when `credentialSource` is "file"`                                                                                   | -              |
|                                     | `privateKeyPEMPath`                       | `string` (secret) | Required when `credentialSource` is "file"`                                                                                   | -              |
|                                     | `publicKeyDERPath`                        | `string`          | Required when `credentialSource` is "rawPublicKey"`                                                                           | -              |
|                                     | `privateKeyDERPath`                       | `string` (secret) | Required when `credentialSource` is "rawPublicKey"`                                                                           | -              |
|                                     | `refreshInterval`                         | `int`             | Optional when `credentialSource` is "file"`                                                                                   | -              |
|                                     | `trustRootsSource`                        | `string`          | Required for `"mTLS"` (permitted values: `"inline"`, `"file"`, `"systemDefaults"`, `"customCertificateVerificationCallback"`) | -              |
|                                     | `trustRootsPEMString`                     | `string`          | Required when `trustRootsSource` is "inline"`                                                                                 | -              |
|                                     | `trustRootsPEMPath`                       | `string`          | Required when `trustRootsSource` is "file"`                                                                                   | -              |
|                                     | `certificateVerificationMode`             | `string`          | Required for `"mTLS"`, permitted values: `"optionalVerification"`, `"noHostnameVerification"`                                 | -              |
| `backpressureStrategy`              | `lowWatermark`                            | `int`             | Optional                                                                                                                      | 2              |
|                                     | `highWatermark`                           | `int`             | Optional                                                                                                                      | 10             |
|                                     | `maxConnections`                          | `int`             | Optional                                                                                                                      | nil            |
| `connectionTimeouts`                | `idle`                                    | `int`             | Optional                                                                                                                      | nil            |
|                                     | `readHeader`                              | `int`             | Optional                                                                                                                      | nil            |
|                                     | `readBody`                                | `int`             | Optional                                                                                                                      | nil            |

#### (m)TLS credentials

Depending on the value provided for `credentialSource` and `trustRootSource`, you may need to provide values for
additional fields:

`credentialSource` determines how server credentials are provided. When set to:
- `"inline"`: The certificate chain and private key must be provided as PEM-encoded strings under the
  `certificateChainPEMString` and `privateKeyPEMString` keys.
- `"file"`: The file paths to PEM-encoded certificate chain and private key files must be provided under the
  `certificateChainPEMPath` and `privateKeyPEMPath` keys.
    - When using this credential source, you may also choose to provide a `refreshInterval`. When this key is set,
      credentials are reloaded periodically at the specified interval (in seconds). Otherwise, credentials are loaded
      from disk once at startup.
- `"rawPublicKey"`: The file paths to DER-encoded public and private keys must be provided under the `publicKeyDERPath`
  and `privateKeyDERPath` keys. Note that raw public key credentials are only supported when serving over HTTP/3.

`trustRootsSource` determines how mTLS trust roots are provided. When set to:
- `"inline"`: The root certificates must be provided as a PEM-encoded string under the `trustRootsPEMString` key.
- `"file"`: The file path to a PEM-encoded root certificate file must be provided under the `trustRootsPEMPath` key.
- `"systemDefaults"`: The operating system's default trust store will be used. There are no other keys to provide.
- `"customCertificateVerificationCallback"`: The custom verification callback must be provided when calling
  ``NIOHTTPServerConfiguration/init(config:customCertificateVerificationCallback:)``.

#### Traits

Some configurations require the package to be built with certain traits enabled:
- For any HTTP/3-related configuration to be parsed, the `HTTP3` trait must be enabled.
- For any configuration under the `http.http3.datagramConfiguration` to be parsed, the `UnstableHTTPDatagrams` trait
  must be enabled.

### Example JSON configuration

The following JSON file shows an example configuration. Comments indicate the default value that would be used if the
key were omitted.

```json
{
    "bindTarget": {
        "host": "0.0.0.0",
        "port": 443
    },
    "http": {
        "versions": ["http1_1", "http2"],
        "http2": {
            "maxFrameSize": 16384,          // default: 2^14 (16384)
            "targetWindowSize": 65535,      // default: 2^16 - 1 (65535)
            "maxConcurrentStreams": 100,    // default: 100
            "gracefulShutdown": {
                "maximumDuration": 30       // default: nil (no time limit)
            }
        }
    },
    "transportSecurity": {
        "mode": "mTLS",
        "credentialSource": "inline",
        "certificateChainPEMString": "-----BEGIN CERTIFICATE-----\n...",
        "privateKeyPEMString": "-----BEGIN PRIVATE KEY-----\n...",
        "trustRootsSource": "inline",
        "trustRootsPEMString": "-----BEGIN CERTIFICATE-----\n...",
        "certificateVerificationMode": "noHostnameVerification"
    },
    "backpressureStrategy": {
        "lowWatermark": 2,                  // default: 2
        "highWatermark": 10                 // default: 10
    },
    "maxConnections": 1000,                 // default: nil (unlimited)
    "connectionTimeouts": {
        "idle": 60,                         // default: nil (no timeout)
        "readHeader": 30,                   // default: nil (no timeout)
        "readBody": 60                      // default: nil (no timeout)
    }
}
```

To bind to multiple addresses, replace `bindTarget` with `bindTargets`, providing parallel `hosts` and `ports` arrays
of the same length:

```json
{
    "bindTargets": {
        "hosts": ["0.0.0.0", "::"],
        "ports": [443, 443]
    },
    // ...rest of the configuration
}
```

### Custom certificate verification

When using mTLS, you can provide a custom certificate verification callback instead of relying on trust roots. To do
so, set `trustRootsSource` to `"customCertificateVerificationCallback"` in the configuration:

```json
{
    "transportSecurity": {
        "mode": "mTLS",
        "credentialSource": "inline",
        "certificateChainPEMString": "...",
        "privateKeyPEMString": "...",
        "trustRootsSource": "customCertificateVerificationCallback",
        "certificateVerificationMode": "noHostnameVerification"
    }
}
```

Then pass the callback when initializing the configuration:

```swift
let serverConfiguration = try NIOHTTPServerConfiguration(
    config: config,
    customCertificateVerificationCallback: { certificates in
        // Perform custom verification logic.
        return .certificateVerified(.init(nil))
    }
)
```

Setting `trustRootsSource` to `"customCertificateVerificationCallback"` without providing a callback, or providing a
callback when `trustRootsSource` is set to something else, will result in a
`NIOHTTPServerSwiftConfigurationError/trustRootsSourceAndVerificationCallbackMismatch` error.
