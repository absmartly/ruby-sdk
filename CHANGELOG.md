## [2.0.0] - Unreleased

Behavior now matches the JavaScript SDK (the reference implementation).

### Breaking
- Read methods (`treatment`, `peek_treatment`, `variable_value`, `peek_variable_value`, `variable_keys`, `custom_field_keys`, `custom_field_value`, `custom_field_value_type`) raise `IllegalStateException` "ABsmartly Context is not yet ready." before the context is ready and "ABsmartly Context is finalized." after `close`, instead of returning 0 / the default. `experiments` raises only when not ready. `publish` and `refresh` raise when not ready.
- The finalize event is named `"finalize"` (`ContextEventLogger::EVENT_TYPE::FINALIZE`); `EVENT_TYPE::CLOSE` is kept as a deprecated alias with the new value.
- `close` after a failed final publish returns the failure and leaves the context open with its events queued, so it can be retried. It used to seal the context and orphan the events.
- A failed `refresh` no longer marks the context failed: it logs the error, returns it and keeps the current data. `refresh` on a failed context is a no-op.
- `ABSmartly.new` is a class-level overload (config object or `endpoint, api_key:, application:, environment:, ...`); subclasses that override `initialize` must adapt.
- `Client#headers` is no longer a public accessor.
- `Array.wrap`, `String#underscore` and `String#compare_to` core extensions removed.
- `match` no longer caps pattern/text length (the JavaScript SDK has no cap); an invalid pattern still evaluates to null.

### Fixed
- Units are hashed from the UTF-8 encoding of their Unicode text: non-UTF-8 strings (e.g. UTF-16) are transcoded, surrogate pairs written as CESU-8 are joined into 4-byte sequences, and lone surrogates or invalid bytes become U+FFFD.
- HTTP: network errors and 5xx responses are retried for both the context fetch and publish; a connection error fails the context instead of raising out of `create_context`.
- A raising event logger no longer breaks the operation that logs (initialization, treatment, publish).
- `in` with an object haystack finds symbol keys (audience attributes are parsed with symbolized names).
- An indeterminate audience result (no filter) keeps a cached assignment instead of re-assigning.
- An exposure or goal can no longer be queued after `close` sealed the context.

### Added
- Configurable connection pool settings: `pool_size` and `pool_idle_timeout`
- Backwards-compatible class aliases: `SDK` (alias for `ABSmartly`) and `SDKConfig` (alias for `ABSmartlyConfig`)

## [0.1.0] - 2022-08-03

- Initial release
