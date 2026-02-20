# Refactoring Plan: Namespace all classes under `Absmartly` module

## Problem

All 55+ classes in the `absmartly-sdk` gem are defined at the **top level** with generic names like `Client`, `Context`, `Unit`, `Attribute`, etc. This pollutes the global Ruby namespace and causes collisions with consuming applications (e.g., `Client` conflicts with `module Client` in host apps using Zeitwerk autoloading).

This violates the standard Ruby gem convention: all code should be wrapped under a namespace module matching the gem name.

## Goal

Wrap all top-level classes under the existing `module Absmartly` and restructure the file layout to follow the `lib/<gem_name>/` convention.

## Namespace choice

Use the existing `module Absmartly` (already defined in `lib/absmartly.rb` and `lib/absmartly/version.rb`). Do **not** use `ABSmartly` — that is a separate class that will become `Absmartly::ABSmartly`.

## Scope

- **59 lib files** to wrap/move
- **32 spec files** to update references
- **1 example file** to update references

---

## Phase 1 — Move files into `lib/absmartly/` and wrap in `module Absmartly`

The standard convention is that directory structure mirrors module nesting. All files (except the entry point `lib/absmartly.rb` and the existing `lib/absmartly/version.rb`) should move into `lib/absmartly/`.

### File moves

```
# Before                                          # After
lib/a_b_smartly.rb                            →   lib/absmartly/a_b_smartly.rb
lib/a_b_smartly_config.rb                     →   lib/absmartly/a_b_smartly_config.rb
lib/audience_deserializer.rb                  →   lib/absmartly/audience_deserializer.rb
lib/audience_matcher.rb                       →   lib/absmartly/audience_matcher.rb
lib/client.rb                                 →   lib/absmartly/client.rb
lib/client_config.rb                          →   lib/absmartly/client_config.rb
lib/context.rb                                →   lib/absmartly/context.rb
lib/context_config.rb                         →   lib/absmartly/context_config.rb
lib/context_data_deserializer.rb              →   lib/absmartly/context_data_deserializer.rb
lib/context_data_provider.rb                  →   lib/absmartly/context_data_provider.rb
lib/context_event_handler.rb                  →   lib/absmartly/context_event_handler.rb
lib/context_event_logger.rb                   →   lib/absmartly/context_event_logger.rb
lib/context_event_logger_callback.rb          →   lib/absmartly/context_event_logger_callback.rb
lib/context_event_serializer.rb               →   lib/absmartly/context_event_serializer.rb
lib/default_audience_deserializer.rb          →   lib/absmartly/default_audience_deserializer.rb
lib/default_context_data_deserializer.rb      →   lib/absmartly/default_context_data_deserializer.rb
lib/default_context_data_provider.rb          →   lib/absmartly/default_context_data_provider.rb
lib/default_context_event_handler.rb          →   lib/absmartly/default_context_event_handler.rb
lib/default_context_event_serializer.rb       →   lib/absmartly/default_context_event_serializer.rb
lib/default_http_client.rb                    →   lib/absmartly/default_http_client.rb
lib/default_http_client_config.rb             →   lib/absmartly/default_http_client_config.rb
lib/default_variable_parser.rb                →   lib/absmartly/default_variable_parser.rb
lib/hashing.rb                                →   lib/absmartly/hashing.rb
lib/http_client.rb                            →   lib/absmartly/http_client.rb
lib/scheduled_executor_service.rb             →   lib/absmartly/scheduled_executor_service.rb
lib/scheduled_thread_pool_executor.rb         →   lib/absmartly/scheduled_thread_pool_executor.rb
lib/string.rb                                 →   lib/absmartly/string.rb (see Phase 2 note)
lib/variable_parser.rb                        →   lib/absmartly/variable_parser.rb
lib/variant_assigner.rb                       →   lib/absmartly/variant_assigner.rb

lib/json/attribute.rb                         →   lib/absmartly/json/attribute.rb
lib/json/context_data.rb                      →   lib/absmartly/json/context_data.rb
lib/json/custom_field_value.rb                →   lib/absmartly/json/custom_field_value.rb
lib/json/experiment.rb                        →   lib/absmartly/json/experiment.rb
lib/json/experiment_application.rb            →   lib/absmartly/json/experiment_application.rb
lib/json/experiment_variant.rb                →   lib/absmartly/json/experiment_variant.rb
lib/json/exposure.rb                          →   lib/absmartly/json/exposure.rb
lib/json/goal_achievement.rb                  →   lib/absmartly/json/goal_achievement.rb
lib/json/publish_event.rb                     →   lib/absmartly/json/publish_event.rb
lib/json/unit.rb                              →   lib/absmartly/json/unit.rb

lib/json_expr/evaluator.rb                    →   lib/absmartly/json_expr/evaluator.rb
lib/json_expr/expr_evaluator.rb               →   lib/absmartly/json_expr/expr_evaluator.rb
lib/json_expr/json_expr.rb                    →   lib/absmartly/json_expr/json_expr.rb
lib/json_expr/operator.rb                     →   lib/absmartly/json_expr/operator.rb

lib/json_expr/operators/and_combinator.rb     →   lib/absmartly/json_expr/operators/and_combinator.rb
lib/json_expr/operators/binary_operator.rb    →   lib/absmartly/json_expr/operators/binary_operator.rb
lib/json_expr/operators/boolean_combinator.rb →   lib/absmartly/json_expr/operators/boolean_combinator.rb
lib/json_expr/operators/equals_operator.rb    →   lib/absmartly/json_expr/operators/equals_operator.rb
lib/json_expr/operators/greater_than_operator.rb          →   lib/absmartly/json_expr/operators/greater_than_operator.rb
lib/json_expr/operators/greater_than_or_equal_operator.rb →   lib/absmartly/json_expr/operators/greater_than_or_equal_operator.rb
lib/json_expr/operators/in_operator.rb        →   lib/absmartly/json_expr/operators/in_operator.rb
lib/json_expr/operators/less_than_operator.rb →   lib/absmartly/json_expr/operators/less_than_operator.rb
lib/json_expr/operators/less_than_or_equal_operator.rb    →   lib/absmartly/json_expr/operators/less_than_or_equal_operator.rb
lib/json_expr/operators/match_operator.rb     →   lib/absmartly/json_expr/operators/match_operator.rb
lib/json_expr/operators/nil_operator.rb       →   lib/absmartly/json_expr/operators/nil_operator.rb
lib/json_expr/operators/not_operator.rb       →   lib/absmartly/json_expr/operators/not_operator.rb
lib/json_expr/operators/or_combinator.rb      →   lib/absmartly/json_expr/operators/or_combinator.rb
lib/json_expr/operators/unary_operator.rb     →   lib/absmartly/json_expr/operators/unary_operator.rb
lib/json_expr/operators/value_operator.rb     →   lib/absmartly/json_expr/operators/value_operator.rb
lib/json_expr/operators/var_operator.rb       →   lib/absmartly/json_expr/operators/var_operator.rb
```

### Code change per file

For every moved file, wrap the class/module definition inside `module Absmartly`:

```ruby
# Before (lib/client.rb)
class Client
  ...
end

# After (lib/absmartly/client.rb)
module Absmartly
  class Client
    ...
  end
end
```

Inheritance declarations (e.g., `class DefaultHttpClient < HttpClient`) resolve automatically since both classes are now inside the same module.

### Entry point update (`lib/absmartly.rb`)

Update all `require_relative` paths:

```ruby
# Before
require_relative "a_b_smartly"
require_relative "client"
require_relative "client_config"

# After
require_relative "absmartly/a_b_smartly"
require_relative "absmartly/client"
require_relative "absmartly/client_config"
```

Internal `require_relative` calls between files within `lib/absmartly/` stay the same (they're at the same depth relative to each other).

### Move rationale

- **Convention**: Every well-structured gem puts code under `lib/<gem_name>/`. Developers expect this layout.
- **Avoids shadowing**: The current `lib/json/` directory shadows Ruby's stdlib `json`. Moving to `lib/absmartly/json/` eliminates that risk.
- **Clear ownership**: Makes it unambiguous which files belong to this gem.

---

## Phase 2 — Do NOT namespace monkey-patches

`lib/string.rb` monkey-patches Ruby's core `String` class (adds a `compare_to` method). This is intentional and cannot be namespaced. Move the file to `lib/absmartly/string.rb` but do **not** wrap `class String` in `module Absmartly`.

Same for the `Array` monkey-patch inside `lib/json_expr/expr_evaluator.rb` — leave it as-is.

---

## Phase 3 — Update cross-references within `lib/`

After wrapping, verify these specific cases:

1. **Inheritance declarations** — e.g., `class DefaultHttpClient < HttpClient` will resolve correctly when both are inside `module Absmartly`. No changes needed.

2. **`require_relative` statements in `lib/absmartly.rb`** — Update paths from `require_relative "client"` to `require_relative "absmartly/client"`.

3. **`require_relative` statements between `lib/absmartly/` files** — These should remain unchanged since relative paths between sibling files are the same.

4. **Explicit class references** — Search all `lib/` files for bare class references like `Client.new(...)`, `ContextConfig.new`, `ABSmartly.new(...)`. Inside the `module Absmartly` wrapper they resolve correctly. Verify carefully.

5. **`lib/absmartly.rb` main entry point** — This file already defines `module Absmartly` and references classes like `ABSmartly`, `ABSmartlyConfig`, `Client`, `ClientConfig`, `ContextConfig`. After the refactor, these references are **inside** the module and resolve correctly. Verify carefully.

6. **`lib/json_expr/json_expr.rb` uses `require` (not `require_relative`)** for operators — update these paths if needed after the move.

---

## Phase 4 — Update all specs

For every spec file, update class references to use fully qualified namespaced names:

```ruby
# Before
RSpec.describe Client do
  subject { Client.new(...) }
end

# After
RSpec.describe Absmartly::Client do
  subject { Absmartly::Client.new(...) }
end
```

### Spec files to update (30 files)

- `spec/a_b_smartly_config_spec.rb` — `ABSmartlyConfig` → `Absmartly::ABSmartlyConfig`
- `spec/a_b_smartly_spec.rb` — `ABSmartly` → `Absmartly::ABSmartly`
- `spec/absmartly_spec.rb` — already uses `Absmartly`, but check internal references
- `spec/audience_matcher_spec.rb` — `AudienceMatcher` → `Absmartly::AudienceMatcher`
- `spec/client_config_spec.rb` — `ClientConfig` → `Absmartly::ClientConfig`
- `spec/client_spec.rb` — `Client` → `Absmartly::Client`
- `spec/context_config_spec.rb` — `ContextConfig` → `Absmartly::ContextConfig`
- `spec/context_spec.rb` — `Context` → `Absmartly::Context` (also update inner class refs like `Assignment`, `ExperimentVariables`, etc.)
- `spec/default_audience_deserializer_spec.rb` — update refs
- `spec/default_context_data_deserializer_spec.rb` — update refs
- `spec/default_http_client_config_spec.rb` — update refs
- `spec/default_http_client_spec.rb` — update refs
- `spec/default_variable_parser_spec.rb` — update refs
- `spec/hashing_spec.rb` — update refs
- `spec/variant_assigner_spec.rb` — update refs
- `spec/json_expr/expr_evaluator_spec.rb` — update refs
- `spec/json_expr/json_expr_spec.rb` — update refs
- All 13 `spec/json_expr/operators/*_spec.rb` — update refs

---

## Phase 5 — Update `example/example.rb`

The example file uses `Absmartly.configure_client`, `Absmartly.create_context`, etc. These methods are defined on `module Absmartly` in `lib/absmartly.rb` and should continue to work.

Check for direct references to unnamespaced classes like `ContextConfig.new` and update to `Absmartly::ContextConfig.new`.

---

## Phase 6 — Backward compatibility aliases (optional)

If backward compatibility is needed (minor/patch release), add a deprecation shim in `lib/absmartly.rb`:

```ruby
# Backward compatibility — deprecated, will be removed in next major version
Client = Absmartly::Client unless defined?(Client)
Context = Absmartly::Context unless defined?(Context)
# ... etc for all previously top-level classes
```

This is **optional** and can be skipped if this is a major version bump.

---

## Phase 7 — Version bump

Update `lib/absmartly/version.rb` from `1.3.0` to `2.0.0` (this is a breaking change in the public API).

---

## Phase 8 — Verify

1. Run `bundle exec rspec` — all specs must pass
2. Add a spec that checks `Object.const_defined?(:Client)` returns `false` to verify no top-level constants are leaked
3. Test integration with a consuming application (e.g., cw-mailer) to confirm the namespace conflict is resolved

---

## Known issues to flag (not in scope for this refactor)

- `ScheduledThreadPoolExecutor < AudienceDeserializer` — suspicious inheritance, likely a copy-paste bug
- `String#compare_to` monkey-patch — should ideally be a refinement or static method
- `Array` monkey-patch in `expr_evaluator.rb` — same concern
- `lib/json/` directory name previously shadowed Ruby's stdlib `json` (resolved by the move to `lib/absmartly/json/`)
