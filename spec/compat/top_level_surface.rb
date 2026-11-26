# frozen_string_literal: true

# Run in a fresh process: ruby -I <lib> top_level_surface.rb <lib> <app_first|sdk_first> <expected names...>
#
# Loads the SDK and drives every public entry point against a local fake
# collector, then prints one JSON line describing the top-level surface. In
# app_first mode the application has already defined a class for every name
# the SDK keeps under Absmartly; those must come through untouched.
require "json"
require "socket"

# The real path: Ruby reports where constants and methods were defined that way.
lib = File.realpath(ARGV.shift)
mode = ARGV.shift
expected = ARGV.map(&:to_sym)
app_first = mode == "app_first"

# The names 1.4.0 adds under Absmartly, which 1.3.0 never defined at top level.
ADDITIONS = %i[ContextDataResult ContextPublisher DefaultContextPublisher PublishError SemverComparator
               SemverEqualsOperator SemverGreaterThanOperator SemverGreaterThanOrEqualOperator
               SemverLessThanOperator SemverLessThanOrEqualOperator SemverOperator TypeUtils].freeze

def fingerprint(klass)
  [klass.instance_methods(false).sort, klass.private_instance_methods(false).sort, klass.singleton_methods.sort,
   klass.constants.sort, klass.ancestors.take_while { |mod| mod != Object },
   klass.singleton_class.ancestors.take_while { |mod| mod != Object.singleton_class }]
end

app_classes = {}
if app_first
  ADDITIONS.each do |name|
    klass = Object.const_set(name, Class.new(RuntimeError) { def app_marker; :app; end })
    app_classes[name] = [klass, fingerprint(klass)]
  end
end

payload = {
  experiments: [{ id: 1, name: "exp", unitType: "session_id", iteration: 1, seedHi: 1, seedLo: 2,
                  split: [0.0, 1.0], trafficSeedHi: 3, trafficSeedLo: 4, trafficSplit: [0, 1],
                  fullOnVariant: 0, applications: [{ name: "a" }],
                  audience: '{"filter":[{"semver_gt":[{"var":"v"},{"value":"1.0.0"}]}]}',
                  customFieldValues: [{ name: "f", value: "x", type: "string" }],
                  variants: [{ name: "A", config: nil }, { name: "B", config: '{"x":1}' }] },
                # 1.4.0's assignment rules and holdouts run too: a split rule and a covering holdout.
                { id: 2, name: "ruled", unitType: "session_id", iteration: 1, seedHi: 1, seedLo: 2,
                  split: [0.5, 0.5], trafficSeedHi: 3, trafficSeedLo: 4, trafficSplit: [0, 1],
                  fullOnVariant: 0, applications: [{ name: "a" }], holdoutIds: [9],
                  assignmentRules: JSON.generate(rules: [{ name: "split", type: "split", environments: [],
                                                          conditions: { and: [{ eq: [{ var: "v" }, { value: "2.0.0" }] }] },
                                                          percentages: "0/100" }]),
                  variants: [{ name: "A", config: '{"y":0}' }, { name: "B", config: '{"y":1}' }] }],
  holdouts: [{ id: 9, name: "holdout", unitType: "session_id", iteration: 1, seedHi: 5, seedLo: 6,
               split: [0.0, 1.0], trafficSeedHi: 0, trafficSeedLo: 0, trafficSplit: [0.0, 1.0],
               fullOnVariant: 0, applications: [], holdoutType: "full",
               variants: [{ name: "A", config: nil }, { name: "B", config: nil }] }]
}.to_json
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
put_status = 200
requests = Hash.new(0)
Thread.new do
  loop do
    Thread.new(server.accept) do |client|
      while (line = client.gets)
        method = line.split.first
        requests[method] += 1
        length = 0
        while (header = client.gets) && header != "\r\n"
          length = header.split(":", 2)[1].to_i if header =~ /\Acontent-length:/i
        end
        client.read(length) if length.positive?
        status = method == "PUT" ? put_status : 200
        body = method == "GET" ? payload : "{}"
        client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{body.bytesize}\r\n\r\n#{body}")
      end
    ensure
      client.close
    end
  end
end

# Core classes the SDK could plausibly extend or mix into. Their method lists
# before require catch an alias of a built-in, which has no source location.
EXTENDED = [Object, Kernel, BasicObject, Module, Class, String, Symbol, Array, Hash, Integer, Float, Numeric,
            Comparable, Enumerable, NilClass, TrueClass, FalseClass, Time].freeze
# Private top-level constants: Ruby lists only public ones, so probe every
# constant-like symbol Ruby knows; const_defined? sees private ones too.
def private_top_level
  public_names = Object.constants
  Symbol.all_symbols.select do |name|
    name.match?(/\A[A-Z]\w*\z/) && !public_names.include?(name) && Object.const_defined?(name, false)
  end
end
method_lists = lambda do
  EXTENDED.to_h do |mod|
    [mod, [mod.instance_methods(false) + mod.private_instance_methods(false),
           mod.singleton_class.instance_methods(false) + mod.singleton_class.private_instance_methods(false)]]
  end
end
methods_before = method_lists.call
before = Object.constants
private_before = private_top_level
object_ancestors_before = Object.ancestors.dup
kernel_ancestors_before = Kernel.ancestors.dup
require "absmartly"
after_require = Object.constants
private_after_require = private_top_level
# A constant counts as the SDK's if it is located in lib or was eval'd. No
# location means it was defined in C, and the SDK has no C code.
sdk_owned = (after_require - before).select do |name|
  path = Object.const_source_location(name)&.first
  path.is_a?(String) && (path.start_with?(lib) || !path.start_with?("/"))
end
# Absmartly is 1.3.0's own module (Absmartly::VERSION); bundler's gemspec may
# have loaded version.rb before this script, from another checkout.
sdk_owned |= [:Absmartly] if Object.const_defined?(:Absmartly, false) && Absmartly.const_defined?(:VERSION, false)

working = []
sdk = ABSmartly.new("http://127.0.0.1:#{port}/v1", api_key: "k", application: "a", environment: "e")
config = ContextConfig.create
config.set_unit(:session_id, "u1")
context = sdk.create_context(config)
context.wait_until_ready
working << (context.ready? && !context.failed?)
context.set_attribute("v", "2.0.0")
working << (context.treatment("exp") == 1)
working << (context.variable_value("x", 0) == 1)
working << (context.peek_treatment("exp") == 1)
working << (context.peek_variable_value("x", 0) == 1)
working << (context.variable_keys[:x] == "exp")
working << context.custom_field_keys.include?("f")
working << (context.custom_field_value("exp", "f") == "x")
working << (context.treatment("ruled") == 1)
working << (context.variable_value("y", 0) == 1)
context.track("goal", { a: 1 })
context.publish
put_status = 503
context.track("rejected", {})
begin
  context.publish
rescue StandardError
  nil
end
put_status = 200
context.refresh
context.set_override("exp", 0)
context.set_custom_assignment("exp", 0)
async = sdk.create_context_async(config)
async.wait_until_ready
working << (async.treatment("exp") == 1)
async.close
with = sdk.create_context_with(config, sdk.context_data)
working << (with.treatment("exp") == 1)
with.close
context.finalize
context.close
Absmartly.configure_client do |client_config|
  client_config.endpoint = "http://127.0.0.1:#{port}/v1"
  client_config.api_key = "k"
  client_config.application = "a"
  client_config.environment = "e"
end
module_context = Absmartly.create_context(Absmartly.create_context_config.tap { |c| c.set_unit(:session_id, "u2") })
module_context.wait_until_ready
working << module_context.ready?
module_context.close
unreachable = ABSmartly.new("http://127.0.0.1:1/v1", api_key: "k", application: "a", environment: "e", retries: 0)
failed = unreachable.create_context(config)
failed.wait_until_ready
working << failed.failed?
failed.close

reachable = ADDITIONS.select do |name|
  resolved = begin
    TOPLEVEL_BINDING.eval(name.to_s)
  rescue NameError
    nil
  end
  app_first ? resolved.equal?(Absmartly.const_get(name)) : (Object.const_defined?(name) || !resolved.nil?)
end
# Ruby's own libraries (pp, json) extend Object; a module that defines
# methods in lib, or any change to Kernel's ancestors, is the SDK's doing.
new_object_ancestors = Object.ancestors - object_ancestors_before
ancestors_changed = Kernel.ancestors != kernel_ancestors_before || new_object_ancestors.any? do |mod|
  (mod.instance_methods(false) + mod.private_instance_methods(false)).any? do |method|
    mod.instance_method(method).source_location&.first.to_s.start_with?(lib)
  end || mod == Absmartly
end
# Methods lib defines on modules it does not own (core classes, gems).
# 1.3.0 already added Array.wrap and String#compare_to, #get_char and
# #underscore; anything beyond those is new.
sdk_module = lambda do |mod|
  root = mod.name.to_s.split("::").first
  root.nil? || root.empty? || root == "Absmartly" || sdk_owned.include?(root.to_sym)
end
foreign_methods_from_lib = []
ObjectSpace.each_object(Module) do |mod|
  next if sdk_module.call(mod)

  [[mod, "#"], [mod.singleton_class, "."]].each do |owner, separator|
    (owner.instance_methods(false) + owner.private_instance_methods(false)).each do |method|
      location = owner.instance_method(method).source_location&.first.to_s
      # An eval'd definition counts as the SDK's when lib called the eval
      # ("(eval at <file>:<line>)"; Ruby's json library defines some this way).
      next unless location.start_with?(lib) || location.start_with?("(eval at #{lib}")

      foreign_methods_from_lib << "#{mod}#{separator}#{method}"
    end
  end
end
# Aliases of built-in methods (no Ruby source location) added since before
# require, on the classes the SDK could plausibly extend.
methods_after = method_lists.call
EXTENDED.each do |mod|
  [[mod, "#", 0], [mod.singleton_class, ".", 1]].each do |owner, separator, index|
    (methods_after[mod][index] - methods_before[mod][index]).each do |method|
      unbound = owner.instance_method(method)
      # An alias keeps its original's name; a C extension method (date's
      # Time#to_date, loaded by a dependency) is its own original.
      next unless unbound.source_location.nil? && unbound.original_name != method

      foreign_methods_from_lib << "#{mod}#{separator}#{method}"
    end
  end
end
# No SDK module mixed into a core class (an include adds no method there).
sdk_mixins = EXTENDED.flat_map do |klass|
  (klass.ancestors + klass.singleton_class.ancestors).select { |mod| sdk_module.call(mod) && mod.name }
                                                     .map { |mod| "#{klass}<#{mod}" }
end
# Resolved as application code does (a bare name at top level), so a class
# made private or replaced by the SDK no longer counts as intact.
app_intact = app_classes.all? do |name, (klass, print)|
  TOPLEVEL_BINDING.eval(name.to_s).equal?(klass) && fingerprint(klass) == print
rescue NameError
  false
end

puts JSON.generate(
  sdk_owned: sdk_owned.sort,
  unexpected: (sdk_owned - expected).sort,
  missing: (expected - sdk_owned).sort,
  added_by_use: (Object.constants - after_require).sort,
  private_top_level_added: ((private_after_require - private_before) | (private_top_level - private_after_require)).sort,
  ancestors_changed: ancestors_changed,
  foreign_methods_from_lib: foreign_methods_from_lib.sort.uniq,
  sdk_mixins: sdk_mixins.uniq,
  reachable: reachable,
  app_intact: app_intact,
  working: working.all? && requests["GET"] >= 4 && requests["PUT"] >= 2
)
