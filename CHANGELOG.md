## [2.0.0] - Unreleased

Behavior now matches the JavaScript SDK (the reference implementation). Each Breaking entry says who is affected.

### Breaking
- After `close`, `experiments`, `set_override` and `set_overrides` no longer raise "ABSmartly Context is closed"; the other read methods still raise it, as in v1.3.0. Before the context is ready, `publish` and `refresh` now raise "ABSmartly Context is not yet ready". Affects code that relied on those raising (or not raising).
- `close` and `refresh` return `nil` (or, for `refresh`, the failure) instead of an Array. Affects code that used their return values.
- `close` and `finalize` after a failed final publish raise the publish error and leave the context open with its events queued, so the caller finds out and can retry: a second `close` republishes and seals, and the `"close"` (or `"finalize"`) event is logged only once the context is sealed. A routine collector rejection (e.g. HTTP 5xx) raises a `PublishError`, a `StandardError`, so it is catchable with an ordinary `rescue`. v1.3.0 sealed the context and orphaned the events. Affects code that called `close` without handling a raised publish error.
- A failed `refresh` no longer marks the context failed: it logs the error, returns it and keeps the current data. `refresh` on a failed context is a no-op.
- The `publish` event is logged only once a publish succeeds; a failed publish logs an `error` event instead. Affects event loggers that counted `publish` events.
- `create_context` no longer raises connection errors such as `Faraday::ConnectionFailed`: the context is returned failed (`failed?` is true) and the error goes to the event logger. `rescue Faraday::ConnectionFailed` around `create_context` no longer triggers.
- A context fetch whose body can't be deserialized now fails the context instead of leaving it never ready.
- Shared variable keys: when several experiments define the same variable, `variable_value` and `peek_variable_value` read from the first experiment, in experiment id order, that the unit is assigned to or overridden in, exposing each experiment visited on the way (as the JavaScript SDK does). v1.3.0 always read and exposed the last experiment in the payload. `variable_keys` likewise now maps a shared key to the experiment with the lowest id instead of the last one in the payload. Affects units in more than one experiment sharing a variable key.
- Numeric audience comparisons follow the JavaScript SDK's number coercion. Affects strict-audience users with numeric attributes, which may move to or from control.
- An audience is re-evaluated after `set_attribute`/`set_attributes` (through the `attrs_seq` counter), as in the JavaScript SDK: when newly supplied attributes flip the audience result, the cached assignment is recomputed, so a unit can move and an extra exposure is sent. v1.3.0 kept the assignment made before the attributes were set. Affects code that set attributes after a treatment or variable read.
- An invalid regex in a `match` audience now sets `audienceMismatch`, so strict audiences assign control. `match` no longer caps pattern/text length.
- Float unit UIDs are hashed from JavaScript's `toFixed(0)` text (e.g. `1.5` as `"2"`), so units with Float UIDs are reassigned. Integer, BigDecimal and Rational UIDs hash as in v1.3.0.
- Strings in non-UTF-8 encodings (e.g. UTF-16) are transcoded to UTF-8 before hashing, so those units are reassigned; surrogate pairs written as CESU-8 are joined and lone surrogates or invalid bytes become U+FFFD. UTF-8 strings are unaffected.
- `track` raises `ArgumentError` for properties that are neither a Hash nor respond to `to_h` (e.g. a String or Array). `ActionController::Parameters` (through `to_unsafe_h`, so unpermitted params are accepted as in v1.3.0) and other `to_h` objects are converted.
- `DefaultContextEventHandler` is a deprecated alias of `DefaultContextPublisher`, so its `.name` is `"DefaultContextPublisher"`. `ContextEventHandler` is likewise an alias of `ContextPublisher`.
- `Array.wrap`, `String#underscore` and `String#compare_to` core extensions removed.

### Fixed
- The `X-Agent` header is now `absmartly-ruby-sdk/<version>` instead of `absmartly-ruby-sdk`.
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
- Assignment rules. An experiment's `assignmentRules` (a JSON string of `{"rules": [...]}`) are evaluated in order, and the first matching rule decides the variant, taking precedence over the audience and `audienceStrict`, traffic eligibility, full-on and custom assignments; only `set_override` beats a rule. An `assign` rule gives a fixed variant; a `split` rule (e.g. `"percentages": "20/30/50"`) hashes the unit with the experiment's own seed over its percentages, which must be non-negative and sum to 100 within 0.01. Rules can be scoped to `environments` (an empty list matches all) and their `conditions` are JSON expressions over the same attributes as audiences, including `application` and `environment`. Rule-assigned exposures carry `ruleOverride: true`, `assigned: false`, `eligible: true`, so the backend excludes them from analysis. A malformed rule is skipped in favour of the next one; an `assign` variant out of range or a split without one percentage per variant stops evaluation and falls back to normal assignment. While the unit is missing, a split rule gives the experiment's no-unit variant (the full-on variant, otherwise 0); once the unit is set, unexposed ones are re-resolved and exposed ones keep their variant. Invalid `assignmentRules` JSON is ignored for that experiment.
- `semver_eq`, `semver_gt`, `semver_gte`, `semver_lt` and `semver_lte` operators for audience filters and rule conditions. A leading `v`/`V` and `+build` metadata are ignored, missing core parts count as `0`, and a release ranks above its pre-releases; an operand that is not a version gives `null`.
- Audience filters now always evaluate `application` and `environment` (the application and environment names configured on the client), matching the JavaScript SDK. The SDK seeds the audience evaluation map with these system values first, then overlays user-set attributes, so a user attribute of the same name always wins, even when set after the context is created (it re-evaluates the cached assignment through `attrs_seq`). Empty or unset names are skipped, so a filter on `environment` with no environment configured leaves the key absent rather than matching `""`. Nothing new is published: the collector already attaches `application` and `environment` server-side, so the publish payload gains no `application`/`environment`/`app_version` attributes. `app_version` is never injected into the evaluation map. **This changes assignment for running experiments: a unit whose experiment has Audience enforced (`audienceStrict`) and an `environment`/`application` condition currently gets variant 0 (control) because the SDK never supplied those attributes; after upgrading, a unit that matches the audience is randomised normally, while a unit that does not match still gets control.**
- `Context#finalize`, which logs the `"finalize"` event (`EVENT_TYPE::FINALIZE`); `close` still logs `"close"` (`EVENT_TYPE::CLOSE`).
- `Context#variable_keys_list`, mapping each variable key to every experiment that defines it, in experiment id order; `variable_keys` still maps it to a single experiment name (see Breaking for which one).
- `retry_statuses` (on `ClientConfig` and `DefaultHttpClientConfig`) to opt in to retrying HTTP statuses, e.g. `[502, 503, 504]`. None are retried by default, as in v1.3.0.
- `retry_connection_failures` to opt in to retrying a refused connection on the context fetch (GET only). Off by default: with the default `max_retries` and backoff, a refused connection would block for about 15 s.
- `ABSmartly.new(endpoint, api_key:, application:, environment:, ...)` alongside `ABSmartly.new(config)`.
- Configurable connection pool settings: `pool_size` and `pool_idle_timeout`

## [0.1.0] - 2022-08-03

- Initial release
