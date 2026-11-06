## [2.0.0] - Unreleased

Behavior now matches the JavaScript SDK (the reference implementation). Each Breaking entry says who is affected.

### Breaking
- After `close`, `experiments`, `set_override` and `set_overrides` no longer raise "ABSmartly Context is closed"; the other read methods still raise it, as in v1.3.0. Before the context is ready, `publish` and `refresh` now raise "ABSmartly Context is not yet ready". Affects code that relied on those raising (or not raising).
- `close` and `refresh` return `nil` (or the failure) instead of an Array. Affects code that used their return values.
- `close` after a failed final publish returns the failure and leaves the context open with its events queued, so it can be retried. It used to seal the context and orphan the events.
- A failed `refresh` no longer marks the context failed: it logs the error, returns it and keeps the current data. `refresh` on a failed context is a no-op.
- The `publish` event is logged only once a publish succeeds; a failed publish logs an `error` event instead. Affects event loggers that counted `publish` events.
- `create_context` no longer raises connection errors such as `Faraday::ConnectionFailed`: the context is returned failed (`failed?` is true) and the error goes to the event logger. `rescue Faraday::ConnectionFailed` around `create_context` no longer triggers.
- A context fetch whose body can't be deserialized now fails the context instead of leaving it never ready.
- Shared variable keys: when several experiments define the same variable, `variable_value` and `peek_variable_value` read from the first experiment, in experiment id order, that the unit is assigned to or overridden in, exposing each experiment visited on the way (as the JavaScript SDK does). v1.3.0 always read and exposed the last experiment in the payload. `variable_keys` likewise now maps a shared key to the experiment with the lowest id instead of the last one in the payload. Affects units in more than one experiment sharing a variable key.
- Numeric audience comparisons follow the JavaScript SDK's number coercion. Affects strict-audience users with numeric attributes, which may move to or from control.
- An invalid regex in a `match` audience now sets `audienceMismatch`, so strict audiences assign control. `match` no longer caps pattern/text length.
- Float unit UIDs are hashed from JavaScript's `toFixed(0)` text (e.g. `1.5` as `"2"`), so units with Float UIDs are reassigned. Integer, BigDecimal and Rational UIDs hash as in v1.3.0.
- Strings in non-UTF-8 encodings (e.g. UTF-16) are transcoded to UTF-8 before hashing, so those units are reassigned; surrogate pairs written as CESU-8 are joined and lone surrogates or invalid bytes become U+FFFD. UTF-8 strings are unaffected.
- `track` raises `ArgumentError` for properties that are neither a Hash nor respond to `to_h` (e.g. a String or Array). `ActionController::Parameters` (through `to_unsafe_h`, so unpermitted params are accepted as in v1.3.0) and other `to_h` objects are converted.
- `DefaultContextEventHandler` is a deprecated alias of `DefaultContextPublisher`, so its `.name` is `"DefaultContextPublisher"`. `ContextEventHandler` is likewise an alias of `ContextPublisher`.
- `Array.wrap`, `String#underscore` and `String#compare_to` core extensions removed.

### Fixed
- `set_unit` stores the `to_s` text of any non-numeric UID (Symbols, `Rack::Session::SessionId`, UUID value objects), as in v1.3.0; `nil` or blank text raises "UID must not be blank."
- Integer unit UIDs are hashed from their exact decimal text, as in v1.3.0, so IDs beyond 2**53 keep distinct buckets.
- `Client#context_data` returns a new immutable `ContextDataResult` per call, so concurrent `create_context_async` calls and refreshes sharing a client can't read each other's in-flight state. The client's `data_future`, `exception` and `promise` readers still reflect the latest fetch.
- A raising event logger no longer breaks the operation that logs (initialization, treatment, publish).
- The SDK writes nothing to stderr, as in v1.3.0; failures are reported to the event logger as `error` events.
- `ABSmartly.new(config)` accepts a duck-typed config that responds to `to_hash` on Ruby 2.7.
- `in` with an object haystack finds symbol keys (audience attributes are parsed with symbolized names).
- An indeterminate audience result (no filter) keeps a cached assignment instead of re-assigning.
- An exposure or goal can no longer be queued after `close` sealed the context.

### Added
- `Context#finalize`, which logs the `"finalize"` event (`EVENT_TYPE::FINALIZE`); `close` still logs `"close"` (`EVENT_TYPE::CLOSE`).
- `Context#variable_keys_list`, mapping each variable key to every experiment that defines it, in experiment id order; `variable_keys` still maps it to a single experiment name (see Breaking for which one).
- `retry_statuses` (on `ClientConfig` and `DefaultHttpClientConfig`) to opt in to retrying HTTP statuses, e.g. `[502, 503, 504]`. None are retried by default, as in v1.3.0.
- `retry_connection_failures` to opt in to retrying a refused connection on the context fetch (GET only). Off by default: with the default `max_retries` and backoff, a refused connection would block for about 15 s.
- `ABSmartly.new(endpoint, api_key:, application:, environment:, ...)` alongside `ABSmartly.new(config)`.
- Configurable connection pool settings: `pool_size` and `pool_idle_timeout`

## [0.1.0] - 2022-08-03

- Initial release
