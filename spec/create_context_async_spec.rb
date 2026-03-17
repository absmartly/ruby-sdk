# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
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
require "logger"

RSpec.describe "create_context_async" do
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
  let(:failure) { Exception.new("FAILED") }

  def slow_client_mock(delay: 0.1)
    client = instance_double(Client)
    allow(client).to receive(:context_data) do
      sleep(delay)
      OpenStruct.new(data_future: data, success?: true)
    end
    client
  end

  def fast_client_mock
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
    client
  end

  def failed_client_mock
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(
      OpenStruct.new(exception: failure, success?: false, data_future: nil)
    )
    client
  end

  describe "ABSmartly#create_context_async" do
    it "returns a context immediately before data is fetched" do
      config = ABSmartlyConfig.create
      config.client = slow_client_mock(delay: 0.5)
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)

      expect(context).to be_a(Context)
      expect(context.ready?).to be false
      expect(context.failed?).to be_falsey

      context.wait_until_ready
      expect(context.ready?).to be true
    end

    it "becomes ready once data is fetched" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      expect(context.ready?).to be true
      expect(context.failed?).to be_falsey
      expect(context.data).to eq(data)
    end

    it "can get treatment after becoming ready" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      treatment = context.treatment("exp_test_ab")
      expect(treatment).to be_a(Integer)
    end

    it "marks context as failed when fetch fails" do
      config = ABSmartlyConfig.create
      config.client = failed_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      expect(context.failed?).to be true
    end

    it "returns 0 for treatment before ready" do
      config = ABSmartlyConfig.create
      config.client = slow_client_mock(delay: 5)
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)

      expect(context.treatment("exp_test_ab")).to eq(0)
    end

    it "validates params just like create_context" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_unit(:user_id, "")

      expect { sdk.create_context_async(context_config) }.to raise_error(ArgumentError)
    end
  end

  describe "Context.create_async" do
    let(:data_provider) { DefaultContextDataProvider.new(fast_client_mock) }

    it "creates an unready context" do
      context = Context.create_async(clock, ContextConfig.create, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      expect(context).to be_a(Context)
      expect(context.ready?).to be false
    end

    it "becomes ready after set_data with success" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      expect(context.ready?).to be false

      context.set_data(OpenStruct.new(data_future: data, success?: true))

      expect(context.ready?).to be true
      expect(context.data).to eq(data)
    end

    it "becomes failed after set_data with failure" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      expect(context.failed?).to be true
    end
  end

  describe "Context#wait_until_ready" do
    it "returns immediately when already ready" do
      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      data_future = data_provider.context_data

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create(clock, context_config, data_future, data_provider,
                               event_handler, event_logger, variable_parser, audience_matcher)

      start = Time.now
      context.wait_until_ready
      elapsed = Time.now - start

      expect(context.ready?).to be true
      expect(elapsed).to be < 0.1
    end

    it "blocks until data arrives from background thread" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      Thread.new do
        sleep(0.05)
        context.set_data(OpenStruct.new(data_future: data, success?: true))
      end

      context.wait_until_ready
      expect(context.ready?).to be true
    end

    it "respects timeout and returns even if not ready" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      start = Time.now
      context.wait_until_ready(0.1)
      elapsed = Time.now - start

      expect(context.ready?).to be false
      expect(elapsed).to be >= 0.09
      expect(elapsed).to be < 0.5
    end

    it "returns self for chaining" do
      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      data_future = data_provider.context_data

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create(clock, context_config, data_future, data_provider,
                               event_handler, event_logger, variable_parser, audience_matcher)

      result = context.wait_until_ready
      expect(result).to eq(context)
    end
  end

  describe "Absmartly.create_context_async" do
    after do
      Absmartly.endpoint = nil
      Absmartly.api_key = nil
      Absmartly.application = nil
      Absmartly.environment = nil
      Absmartly.event_logger = nil
      Absmartly.instance_variable_set(:@sdk, nil)
      Absmartly.instance_variable_set(:@sdk_config, nil)
    end

    it "creates an async context via the module interface" do
      allow(Client).to receive(:create).and_return(fast_client_mock)

      Absmartly.configure_client do |config|
        config.endpoint = "https://test.absmartly.io/v1"
        config.api_key = "test-key"
        config.application = "test-app"
        config.environment = "test"
      end

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Absmartly.create_context_async(context_config)
      expect(context).to be_a(Context)

      context.wait_until_ready
      expect(context.ready?).to be true
    end
  end
end
