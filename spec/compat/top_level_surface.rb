# frozen_string_literal: true

# Run in a fresh process: ruby -I <lib> top_level_surface.rb <lib> <app_first|sdk_first> <expected names...>
#
# Loads the SDK and drives every public entry point against a local fake
# collector, then prints one JSON line describing the top-level constant
# surface. In app_first mode the application has already defined a class for
# every name the SDK keeps under Absmartly; those must come through untouched.
require "json"
require "socket"

lib = File.expand_path(ARGV.shift)
mode = ARGV.shift
expected = ARGV.map(&:to_sym)
app_first = mode == "app_first"

# The names 1.4.0 adds under Absmartly, which 1.3.0 never defined at top level.
ADDITIONS = %i[ContextDataResult ContextPublisher DefaultContextPublisher PublishError SemverComparator
               SemverEqualsOperator SemverGreaterThanOperator SemverGreaterThanOrEqualOperator
               SemverLessThanOperator SemverLessThanOrEqualOperator SemverOperator TypeUtils].freeze

app_classes = {}
if app_first
  ADDITIONS.each do |name|
    klass = Object.const_set(name, Class.new(RuntimeError) { def app_marker; :app; end })
    app_classes[name] = [klass, klass.instance_methods(false).sort, klass.singleton_methods.sort]
  end
end
payload = {
  experiments: [{ id: 1, name: "exp", unitType: "session_id", iteration: 1, seedHi: 1, seedLo: 2,
                  split: [0.5, 0.5], trafficSeedHi: 3, trafficSeedLo: 4, trafficSplit: [0, 1],
                  fullOnVariant: 0, applications: [{ name: "a" }],
                  audience: '{"filter":[{"semver_gt":[{"var":"v"},{"value":"1.0.0"}]}]}',
                  variants: [{ name: "A", config: nil }, { name: "B", config: '{"x":1}' }] }]
}.to_json
server = TCPServer.new("127.0.0.1", 0)
port = server.addr[1]
put_status = 200
Thread.new do
  loop do
    Thread.new(server.accept) do |client|
      while (line = client.gets)
        method = line.split.first
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

before = Object.constants
require "absmartly"
after_require = Object.constants
# Ruby's own libraries (pp, json) extend Object; the SDK must not, on use either.
ancestors = Object.ancestors.dup
# A constant counts as the SDK's if it is located in lib or was eval'd.
sdk_owned = (after_require - before).select do |name|
  # No location: defined in C (the SDK has no C code). An eval'd definition
  # has a path that is not absolute, so it counts.
  path = Object.const_source_location(name)&.first
  path.is_a?(String) && (path.start_with?(lib) || !path.start_with?("/"))
end
# Absmartly is 1.3.0's own module (Absmartly::VERSION); bundler's gemspec may
# have loaded version.rb before this script, from another checkout.
sdk_owned |= [:Absmartly] if Object.const_defined?(:Absmartly, false) && Absmartly.const_defined?(:VERSION, false)

sdk = ABSmartly.new("http://127.0.0.1:#{port}/v1", api_key: "k", application: "a", environment: "e")
config = ContextConfig.create
config.set_unit(:session_id, "u1")
context = sdk.create_context(config)
context.wait_until_ready
context.set_attribute("v", "2.0.0")
context.treatment("exp")
context.variable_value("x", 0)
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
async = sdk.create_context_async(config)
async.wait_until_ready
async.treatment("exp")
async.close
with = sdk.create_context_with(config, sdk.context_data)
with.treatment("exp")
with.close
context.close

reachable = ADDITIONS.select do |name|
  if app_first
    Object.const_get(name).equal?(Absmartly.const_get(name))
  else
    Object.const_defined?(name)
  end
end
app_intact = app_classes.all? do |name, (klass, instance_methods, singleton_methods)|
  Object.const_get(name).equal?(klass) && klass.instance_methods(false).sort == instance_methods &&
    klass.singleton_methods.sort == singleton_methods
end

puts JSON.generate(
  sdk_owned: sdk_owned.sort,
  unexpected: (sdk_owned - expected).sort,
  missing: (expected - sdk_owned).sort,
  added_by_use: (Object.constants - after_require).sort,
  ancestors_changed: Object.ancestors != ancestors,
  reachable: reachable,
  app_intact: app_intact
)
