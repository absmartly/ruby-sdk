# frozen_string_literal: true

require "ostruct"
require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "context_data_provider"
require "default_context_data_provider"
require "context_event_handler"
require "context_event_logger"
require "audience_matcher"
require "json/unit"
require "a_b_smartly"
require "a_b_smartly_config"
require "client"
require "client_config"
require "context_event_logger_callback"
require "json_expr/operators/match_operator"

RSpec.describe "Fix Plan Validations" do
  let(:units) {
    {
      session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
      user_id: "123456789",
      email: "bleh@absmartly.com"
    }
  }
  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }
  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:event_handler) do
    ev = instance_double(ContextEventHandler)
    allow(ev).to receive(:publish).and_return(publish_future)
    ev
  end
  let(:event_logger) { nil }
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }

  def client_mock(data_future = nil)
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data_future || data, success?: true))
    client
  end

  let(:data_provider) { DefaultContextDataProvider.new(client_mock) }
  let(:data_future_ready) { data_provider.context_data }

  def create_ready_context(evt_handler: nil)
    config = ContextConfig.create
    config.set_units(units)
    Context.create(clock, config, data_future_ready, data_provider,
                   evt_handler || event_handler, event_logger, variable_parser, audience_matcher)
  end

  describe "Fix #1: Thread safety with Mutex" do
    it "handles concurrent track calls without losing events" do
      context = create_ready_context
      errors = []
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          10.times do
            begin
              context.track("goal", { value: 1 })
            rescue => e
              mutex.synchronize { errors << e }
            end
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      expect(context.pending_count).to eq(100)
    end

    it "handles concurrent treatment calls and exposure queueing" do
      context = create_ready_context
      errors = []
      mutex = Mutex.new

      threads = 10.times.map do
        Thread.new do
          begin
            context.treatment("exp_test_ab")
          rescue => e
            mutex.synchronize { errors << e }
          end
        end
      end

      threads.each(&:join)

      expect(errors).to be_empty
      exposures = context.instance_variable_get(:@exposures)
      expect(exposures.length).to be <= 10
    end

    it "flush atomically clears events before publishing" do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(publish_future)

      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)
      context.track("goal2", nil)
      expect(context.pending_count).to eq(2)

      context.publish

      expect(context.pending_count).to eq(0)
    end
  end

  describe "Fix #2/#13/#21: MatchOperator" do
    let(:operator) { MatchOperator.new }
    let(:evaluator) do
      ev = double("evaluator")
      allow(ev).to receive(:evaluate) { |arg| arg }
      allow(ev).to receive(:string_convert) { |arg| arg.is_a?(String) ? arg : nil }
      ev
    end

    it "returns true/false (boolean) instead of MatchData" do
      result = operator.binary(evaluator, "abcdef", "abc")
      expect(result).to be(true)

      result = operator.binary(evaluator, "abcdef", "xyz")
      expect(result).to be(false)
    end

    it "returns nil for patterns exceeding MAX_PATTERN_LENGTH" do
      long_pattern = "a" * 1001
      result = operator.binary(evaluator, "test", long_pattern)
      expect(result).to be_nil
    end

    it "returns nil for text exceeding MAX_TEXT_LENGTH" do
      long_text = "a" * 10_001
      result = operator.binary(evaluator, long_text, "a")
      expect(result).to be_nil
    end

    it "returns nil for invalid regex patterns" do
      result = operator.binary(evaluator, "test", "[invalid")
      expect(result).to be_nil
    end

    it "does not use Timeout.timeout" do
      expect(defined?(Timeout)).to be_nil.or(satisfy { |_|
        source = File.read(File.join("lib", "json_expr", "operators", "match_operator.rb"))
        !source.include?("Timeout.timeout")
      })
    end
  end

  describe "Fix #4: create_context_async error handling" do
    it "handles exception in data provider thread" do
      failing_provider = instance_double(ContextDataProvider)
      allow(failing_provider).to receive(:context_data).and_raise(RuntimeError, "connection failed")

      config = ABSmartlyConfig.create
      config.client = instance_double(Client)
      config.context_data_provider = failing_provider
      config.context_event_handler = event_handler

      absmartly = ABSmartly.create(config)

      ctx_config = ContextConfig.create
      ctx_config.set_unit(:session_id, "test123")

      context = absmartly.create_context_async(ctx_config)
      context.wait_until_ready(2)

      expect(context.failed?).to be(true)
    end
  end

  describe "Fix #5: Redundant nil check in ContextEventLoggerCallback" do
    it "calls callable when present" do
      called = false
      callback = ContextEventLoggerCallback.new(->(_event, _data) { called = true })
      callback.handle_event("test", nil)
      expect(called).to be(true)
    end

    it "does not call when callable is nil" do
      callback = ContextEventLoggerCallback.new(nil)
      expect { callback.handle_event("test", nil) }.not_to raise_error
    end
  end

  describe "Fix #6: @index initialization as Hash" do
    it "initializes @index as a Hash" do
      context = create_ready_context
      index = context.instance_variable_get(:@index)
      expect(index).to be_a(Hash)
    end
  end

  describe "Fix #7: @exposures initialization without ||=" do
    it "initializes @exposures as empty array" do
      context = create_ready_context
      exposures = context.instance_variable_get(:@exposures)
      expect(exposures).to eq([])
    end
  end

  describe "Fix #10: Simplified publish method" do
    it "returns flush result directly" do
      context = create_ready_context
      context.track("goal", nil)
      result = context.publish
      expect(result).to eq(publish_future)
    end
  end

  describe "Fix #12: Backtrace leak in AudienceMatcher" do
    it "does not include backtrace in error output" do
      matcher = AudienceMatcher.new(DefaultAudienceDeserializer.new)
      warnings = []
      allow(matcher).to receive(:warn) { |msg| warnings << msg }

      matcher.evaluate("not json {{", {})

      expect(warnings.first).not_to include("\n")
    end
  end

  describe "Fix #14: Client headers not publicly accessible" do
    it "does not expose headers as a public method" do
      config = ClientConfig.create
      config.endpoint = "https://localhost/v1"
      config.api_key = "test-key"
      config.application = "test"
      config.environment = "dev"

      http_client = instance_double(DefaultHttpClient)
      allow(DefaultHttpClient).to receive(:create).and_return(http_client)

      client = Client.create(config)
      expect { client.headers }.to raise_error(NoMethodError)
    end
  end

  describe "Fix #15: DefaultAudienceDeserializer offset/length" do
    it "uses offset+length slicing (not range)" do
      deser = DefaultAudienceDeserializer.new
      audience = "{\"filter\":[{\"gte\":[{\"var\":\"age\"},{\"value\":20}]}]}"
      expected = { filter: [{ gte: [{ var: "age" }, { value: 20 }] }] }

      result = deser.deserialize(audience, 0, audience.length)
      expect(result).to eq(expected)
    end

    it "handles non-zero offset correctly" do
      deser = DefaultAudienceDeserializer.new
      prefix = "XXXX"
      json_str = '{"key":"val"}'
      bytes = prefix + json_str

      result = deser.deserialize(bytes, prefix.length, json_str.length)
      expect(result).to eq({ key: "val" })
    end
  end

  describe "Fix #16: transform_keys hot path removed" do
    it "looks up experiments without transform_keys on every call" do
      context = create_ready_context
      source = File.read(File.join("lib", "context.rb"))
      experiment_method = source[/def experiment\(experiment\).*?end/m]
      expect(experiment_method).not_to include("transform_keys")
    end

    it "looks up variable_experiment without transform_keys on every call" do
      context = create_ready_context
      source = File.read(File.join("lib", "context.rb"))
      variable_method = source[/def variable_experiment\(key\).*?end/m]
      expect(variable_method).not_to include("transform_keys")
    end
  end

  describe "Fix #17: set_unit stores keys as symbols" do
    it "stores unit with symbol key when called with string" do
      context = create_ready_context
      context.set_unit("db_user_id", "test_uid")

      units_ivar = context.instance_variable_get(:@units)
      expect(units_ivar[:db_user_id]).to eq("test_uid")
      expect(units_ivar["db_user_id"]).to be_nil
    end

    it "stores unit with symbol key when called with symbol" do
      context = create_ready_context
      context.set_unit(:db_user_id, "test_uid")

      units_ivar = context.instance_variable_get(:@units)
      expect(units_ivar[:db_user_id]).to eq("test_uid")
    end

    it "detects duplicate units regardless of key type" do
      context = create_ready_context
      context.set_unit("db_user_id", "test_uid")

      expect {
        context.set_unit(:db_user_id, "different_uid")
      }.to raise_error(IllegalStateException)
    end
  end

  describe "Fix #20: camelCase instance variable renamed" do
    it "uses snake_case @experiment_custom_field_values" do
      context = create_ready_context
      source = File.read(File.join("lib", "context.rb"))
      expect(source).not_to include("@experimentCustomFieldValues")
      expect(source).to include("@experiment_custom_field_values")
    end
  end

  describe "Fix #19: require 'ostruct' in specs" do
    it "OpenStruct is available" do
      expect(defined?(OpenStruct)).to eq("constant")
    end
  end

  describe "Fix 1.3: publish error handling preserves events on failure" do
    it "preserves pending_count after publish failure" do
      ev = instance_double(ContextEventHandler)
      failure = Exception.new("FAILED")
      failure_future = OpenStruct.new(exception: failure, success?: false, data_future: nil)
      allow(ev).to receive(:publish).and_return(failure_future)

      config = ContextConfig.create
      config.set_units({ session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec" })

      context = Context.create(clock, config, data_future_ready, data_provider,
                               ev, nil, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new))

      context.track("goal1", nil)
      expect(context.pending_count).to eq(1)

      context.publish

      expect(context.pending_count).to eq(1)
    end

    it "clears pending_count after successful publish" do
      config = ContextConfig.create
      config.set_units({ session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec" })

      context = Context.create(clock, config, data_future_ready, data_provider,
                               event_handler, nil, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new))

      context.track("goal1", nil)
      expect(context.pending_count).to eq(1)

      context.publish

      expect(context.pending_count).to eq(0)
    end
  end

  describe "Fix 4.1: set_override works after context is closed" do
    it "allows set_override after close without raising" do
      context = create_ready_context
      context.close

      expect { context.set_override("exp_test_ab", 2) }.not_to raise_error
    end

    it "allows set_overrides after close without raising" do
      context = create_ready_context
      context.close

      expect { context.set_overrides("exp_test_ab": 2) }.not_to raise_error
    end
  end

  describe "Fix 1.1: variableKeys returns array of experiment names" do
    it "maps each variable key to an array of experiment names" do
      context = create_ready_context
      keys = context.variable_keys
      keys.each do |_key, names|
        expect(names).to be_a(Array)
        expect(names).not_to be_empty
      end
    end

    it "includes both experiment names when two experiments share a variable key" do
      descr = DefaultContextDataDeserializer.new

      exp_a_variant_b = { "name" => "B", "config" => '{"shared.key":"from_exp_a"}' }
      exp_b_variant_b = { "name" => "B", "config" => '{"shared.key":"from_exp_b"}' }

      exp_a = {
        "id" => 1, "name" => "exp_a", "unitType" => "session_id",
        "iteration" => 1, "seedHi" => 0, "seedLo" => 0,
        "split" => [0.5, 0.5], "trafficSeedHi" => 0, "trafficSeedLo" => 0,
        "trafficSplit" => [0.0, 1.0], "fullOnVariant" => 0,
        "variants" => [{ "name" => "A", "config" => nil }, exp_a_variant_b],
        "audienceStrict" => false, "audience" => ""
      }
      exp_b = {
        "id" => 2, "name" => "exp_b", "unitType" => "session_id",
        "iteration" => 1, "seedHi" => 0, "seedLo" => 0,
        "split" => [0.5, 0.5], "trafficSeedHi" => 0, "trafficSeedLo" => 0,
        "trafficSplit" => [0.0, 1.0], "fullOnVariant" => 0,
        "variants" => [{ "name" => "A", "config" => nil }, exp_b_variant_b],
        "audienceStrict" => false, "audience" => ""
      }

      json = JSON.generate({ "experiments" => [exp_a, exp_b] })
      shared_data = descr.deserialize(json, 0, json.length)

      shared_client = instance_double(Client)
      allow(shared_client).to receive(:context_data).and_return(
        OpenStruct.new(data_future: shared_data, success?: true)
      )
      shared_provider = DefaultContextDataProvider.new(shared_client)
      shared_future = shared_provider.context_data

      config = ContextConfig.create
      config.set_unit(:session_id, "test-unit")

      context = Context.create(clock, config, shared_future, shared_provider,
                               event_handler, nil, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new))

      keys = context.variable_keys
      expect(keys[:"shared.key"]).to be_a(Array)
      expect(keys[:"shared.key"]).to include("exp_a")
      expect(keys[:"shared.key"]).to include("exp_b")
    end
  end
end
