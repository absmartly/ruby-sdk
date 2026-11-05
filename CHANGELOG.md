## [2.0.0] - Unreleased

Behavior now matches the JavaScript SDK (the reference implementation).

### Breaking
- Read methods (`treatment`, `peek_treatment`, `variable_value`, `peek_variable_value`, `variable_keys`, `custom_field_keys`, `custom_field_value`, `custom_field_value_type`) raise `IllegalStateException` "ABSmartly Context is not yet ready" before the context is ready and "ABSmartly Context is closed" after `close` (the v1.3.0 messages), instead of returning 0 / the default. `experiments` raises only when not ready. `publish` and `refresh` raise when not ready.
- `close` after a failed final publish returns the failure and leaves the context open with its events queued, so it can be retried. It used to seal the context and orphan the events.
- A failed `refresh` no longer marks the context failed: it logs the error, returns it and keeps the current data. `refresh` on a failed context is a no-op.
- `Array.wrap`, `String#underscore` and `String#compare_to` core extensions removed.
- `match` no longer caps pattern/text length (the JavaScript SDK has no cap); an invalid pattern still evaluates to null.

### Fixed
- Units are hashed from the UTF-8 encoding of their Unicode text: non-UTF-8 strings (e.g. UTF-16) are transcoded, surrogate pairs written as CESU-8 are joined into 4-byte sequences, and lone surrogates or invalid bytes become U+FFFD.
- HTTP: a refused connection is retried on the context fetch (GET only); a connection error fails the context instead of raising out of `create_context`. Status codes are still not retried by default, as in v1.3.0.
- Integer unit UIDs are hashed from their exact decimal text, as in v1.3.0, so IDs beyond 2**53 keep distinct buckets; other numbers are hashed from their JavaScript `toFixed(0)` text.
- `Client#context_data` returns a new immutable `ContextDataResult` per call, so concurrent `create_context_async` calls and refreshes sharing a client can't read each other's in-flight state. The client's `data_future`, `exception` and `promise` readers still reflect the latest fetch.
- `set_unit` converts Symbols and String-like objects (`to_str`) to Strings, as in v1.3.0; `nil` raises "UID must not be blank."
- A raising event logger no longer breaks the operation that logs (initialization, treatment, publish).
- `in` with an object haystack finds symbol keys (audience attributes are parsed with symbolized names).
- An indeterminate audience result (no filter) keeps a cached assignment instead of re-assigning.
- An exposure or goal can no longer be queued after `close` sealed the context.

### Added
- `Context#finalize`, which logs the `"finalize"` event (`EVENT_TYPE::FINALIZE`); `close` still logs `"close"` (`EVENT_TYPE::CLOSE`).
- `Context#variable_keys_list`, mapping each variable key to every experiment that defines it; `variable_keys` still maps it to a single experiment name.
- `DefaultHttpClientConfig#retry_statuses` to opt in to retrying HTTP statuses (e.g. `[502, 503, 504]`).
- `ABSmartly.new(endpoint, api_key:, application:, environment:, ...)` alongside `ABSmartly.new(config)`.
- Configurable connection pool settings: `pool_size` and `pool_idle_timeout`
- Backwards-compatible class aliases: `SDK` (alias for `ABSmartly`) and `SDKConfig` (alias for `ABSmartlyConfig`)

## [0.1.0] - 2022-08-03

- Initial release
