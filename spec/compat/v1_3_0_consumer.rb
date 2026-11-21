# frozen_string_literal: true

# A customer app written against absmartly-sdk 1.3.0's README and public classes.
# Run in a fresh process by spec/compat_v1_3_0_spec.rb; keep it in 1.3.0's API only.
require "absmartly"
require "json"

results = []
check = ->(name, cond) { results << [name, cond ? "ok" : "FAIL"] }

# Extension points subclassed the way 1.3.0 allowed.
class MyEventLogger < ContextEventLogger
  attr_reader :events
  def initialize; @events = []; end
  def handle_event(event, data)
    case event
    when EVENT_TYPE::EXPOSURE, EVENT_TYPE::GOAL, EVENT_TYPE::ERROR, EVENT_TYPE::PUBLISH,
         EVENT_TYPE::READY, EVENT_TYPE::REFRESH, EVENT_TYPE::CLOSE
      @events << event
    end
  end
end
class MyHandler < ContextEventHandler
  attr_reader :n
  def publish(context, event); @n = (@n || 0) + 1; nil; end
end
class MyDefaultHandler < DefaultContextEventHandler; end
class MyProvider < ContextDataProvider
  def context_data
    raw = { experiments: [{ id: 1, name: "exp_test_experiment", unitType: "session_id", iteration: 1, seedHi: 3603515,
                            seedLo: 233373850, split: [0.5, 0.5], trafficSeedHi: 449867249, trafficSeedLo: 455443629,
                            trafficSplit: [0.0, 1.0], fullOnVariant: 0, applications: [{ name: "website" }],
                            variants: [{ name: "A", config: nil }, { name: "B", config: '{"button.color":"red"}' }],
                            audienceStrict: false, audience: nil }] }.to_json
    Struct.new(:data_future) { def success?; true; end }.new(DefaultContextDataDeserializer.new.deserialize(raw, 0, raw.size))
  end
end
class MyParser < VariableParser
  def parse(context, experiment_name, variant_name, config); JSON.parse(config, symbolize_names: true); end
end
class MyAudienceDeserializer < AudienceDeserializer
  def deserialize(bytes, offset, length); JSON.parse(bytes, symbolize_names: true); end
end
class MyExecutor < ScheduledThreadPoolExecutor; end

check.("DefaultContextEventHandler < ContextEventHandler", DefaultContextEventHandler.superclass == ContextEventHandler)
check.("ScheduledThreadPoolExecutor < AudienceDeserializer", ScheduledThreadPoolExecutor.superclass == AudienceDeserializer)
check.("core ext Array.wrap", Array.wrap(nil) == [] && Array.wrap(1) == [1])
check.("core ext String#underscore/compare_to", "FooBar".underscore == "foo_bar" && "a".compare_to("b") < 0)
check.("Absmartly::Error", Absmartly::Error.ancestors.include?(StandardError))

# README: global configuration.
Absmartly.configure_client do |config|
  config.endpoint = "https://your-company.absmartly.io/v1"
  config.api_key = "YOUR-API-KEY"
  config.application = "website"
  config.environment = "development"
  config.connect_timeout = 3.0
  config.connection_request_timeout = 3.0
  config.retry_interval = 0.5
  config.max_retries = 5
  config.event_logger = MyEventLogger.new
end
check.("Absmartly.create_context_config", Absmartly.create_context_config.is_a?(ContextConfig))

# README: explicit client config.
client_config = ClientConfig.new(endpoint: "https://your-company.absmartly.io/v1", api_key: "YOUR-API-KEY",
                                 application: "website", environment: "development")
sdk_config = ABSmartlyConfig.create
sdk_config.client = Client.create(client_config)
check.("Client#headers X-Agent prefix", sdk_config.client.headers[:"X-Agent"].start_with?("absmartly-ruby-sdk"))
check.("Absmartly.create (global config)", Absmartly.create.is_a?(ABSmartly))
sdk = ABSmartly.create(sdk_config)
check.("ABSmartly.create", sdk.is_a?(ABSmartly))
check.("default handler is DefaultContextEventHandler", ABSmartly.create(sdk_config).context_event_handler.instance_of?(DefaultContextEventHandler))

logger = MyEventLogger.new
handler = MyHandler.new
cfg = ABSmartlyConfig.create
cfg.context_data_provider = MyProvider.new
cfg.context_event_handler = handler
cfg.context_event_logger = logger
cfg.variable_parser = MyParser.new
cfg.audience_deserializer = MyAudienceDeserializer.new
cfg.scheduler = MyExecutor.new
sdk = ABSmartly.create(cfg)

context_config = Absmartly.create_context_config
context_config.set_unit("session_id", "bf06d8cb5d8137290c4abb64155584fbdb64d8")
context_config.set_units(user_id: "123456")
context = sdk.create_context(context_config)
check.("ready", context.ready?)
treatment = context.treatment("exp_test_experiment")
check.("treatment Integer", treatment.is_a?(Integer))
check.("variable_value", %w[red blue].include?(context.variable_value("button.color", "blue")))
check.("peek_treatment", context.peek_treatment("exp_test_experiment") == treatment)
check.("variable_keys shape", context.variable_keys == { "button.color": "exp_test_experiment" })
context.set_override("exp_test_experiment", 1)
context.set_overrides("exp_test_experiment" => 1, "exp_another_experiment" => 0)
context.set_attribute("session_id", "x")
context.set_attributes("customer_age" => "new_customer")
context.set_custom_assignment("experiment_name", 1)
context.set_custom_assignments("experiment_name" => 1, "another_experiment_name" => 0)
context.track("payment", { item_count: 1, total_amount: 1999.99 })
context.publish
r = context.refresh
check.("refresh returns logger result", r == logger.events)
close_result = context.close
check.("close returns logger result", close_result == logger.events)
check.("closed?", context.closed?)
begin
  context.treatment("exp_test_experiment"); check.("closed raises", false)
rescue IllegalStateException => e
  check.("closed raises IllegalStateException text", e.message == "ABSmartly Context is closed")
end
begin
  context.set_override("exp", 1); check.("set_override after close raises", false)
rescue IllegalStateException
  check.("set_override after close raises", true)
end
begin
  context.experiments; check.("experiments after close raises", false)
rescue IllegalStateException
  check.("experiments after close raises", true)
end
check.("events", logger.events.include?("close") && logger.events.include?("publish"))

# Rejected final publish on close: logged and sealed, no raise (1.3.0).
class RejectingHandler < ContextEventHandler
  def publish(context, event); Exception.new("rejected"); end
end
cfg.context_event_handler = RejectingHandler.new
ctx2 = ABSmartly.create(cfg).create_context(context_config)
ctx2.treatment("exp_test_experiment")
begin
  ctx2.close
  check.("close on rejected publish does not raise and seals", ctx2.closed? && ctx2.pending_count == 0)
rescue Exception => e
  check.("close on rejected publish does not raise (#{e.class})", false)
end

# Float/encoded UIDs hash from to_s bytes as in 1.3.0.
check.("Hashing.hash_unit(1.5)", Hashing.hash_unit(1.5) == Hashing.hash_unit("1.5"))
check.("VariantAssigner float", VariantAssigner.new(125.75).key == VariantAssigner.new("125.75").key)

results.each { |n, s| puts "#{s} #{n}" }
exit(results.all? { |_, s| s == "ok" } ? 0 : 1)
