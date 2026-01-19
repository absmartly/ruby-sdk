# frozen_string_literal: true

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

class MockContextEventLoggerProxy < ContextEventLogger
  attr_accessor :called, :events, :logger

  def initialize
    @called = 0
    @events = []
    @logger = Logger.new(STDOUT)
    @logger.level = Logger::WARN
  end

  def handle_event(event, data)
    @called += 1
    @events << { event: event, data: data }
  end

  def clear
    @called = 0
    @events = []
  end
end

RSpec.describe Absmartly do
  it "has a version number" do
    expect(Absmartly::VERSION).not_to be nil
  end

  describe ".configure_client" do
    after do
      Absmartly.endpoint = nil
      Absmartly.api_key = nil
      Absmartly.application = nil
      Absmartly.environment = nil
      Absmartly.connect_timeout = nil
      Absmartly.connection_request_timeout = nil
      Absmartly.retry_interval = nil
      Absmartly.max_retries = nil
    end

    it "sets HTTP config options" do
      Absmartly.configure_client do |config|
        config.endpoint = "https://test.absmartly.io/v1"
        config.api_key = "test-api-key"
        config.application = "website"
        config.environment = "development"
        config.connect_timeout = 5.0
        config.connection_request_timeout = 10.0
        config.retry_interval = 1.0
        config.max_retries = 3
      end

      expect(Absmartly.endpoint).to eq("https://test.absmartly.io/v1")
      expect(Absmartly.api_key).to eq("test-api-key")
      expect(Absmartly.application).to eq("website")
      expect(Absmartly.environment).to eq("development")
      expect(Absmartly.connect_timeout).to eq(5.0)
      expect(Absmartly.connection_request_timeout).to eq(10.0)
      expect(Absmartly.retry_interval).to eq(1.0)
      expect(Absmartly.max_retries).to eq(3)
    end
  end

  describe ".event_logger" do
    after do
      Absmartly.event_logger = nil
    end

    it "has event_logger accessor" do
      expect(Absmartly).to respond_to(:event_logger)
      expect(Absmartly).to respond_to(:event_logger=)
    end

    it "can be set via configure_client" do
      logger = double("event_logger")

      Absmartly.configure_client do |config|
        config.event_logger = logger
      end

      expect(Absmartly.event_logger).to eq(logger)
    end

    it "flows through to ABSmartlyConfig.context_event_logger" do
      logger = double("event_logger")

      Absmartly.configure_client do |config|
        config.endpoint = "https://test.absmartly.io/v1"
        config.api_key = "test-api-key"
        config.application = "test-app"
        config.environment = "test"
        config.event_logger = logger
      end

      sdk_config = Absmartly.send(:sdk_config)
      expect(sdk_config.context_event_logger).to eq(logger)
    end
  end

  describe ".event_logger integration" do
    let(:units) do
      {
        session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
        user_id: "123456789",
        email: "bleh@absmartly.com"
      }
    end
    let(:publish_units) do
      [
        Unit.new("session_id", "pAE3a1i5Drs5mKRNq56adA"),
        Unit.new("user_id", "JfnnlDI7RTiF9RgfG2JNCw"),
        Unit.new("email", "IuqYkNRfEx5yClel4j3NbA")
      ]
    end
    let(:clock) { Time.at(1620000000000 / 1000) }
    let(:clock_in_millis) { clock.to_i }

    let(:descr) { DefaultContextDataDeserializer.new }
    let(:json) { resource("context.json") }
    let(:data) { descr.deserialize(json, 0, json.length) }

    let(:data_future) { OpenStruct.new(data_future: nil, success?: true) }

    let(:data_provider) { DefaultContextDataProvider.new(client_mock) }
    let(:data_future_ready) { data_provider.context_data }

    let(:publish_future) { OpenStruct.new(success?: true) }
    let(:event_handler) do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(publish_future)
      ev
    end

    let(:mock_logger) do
      logger = MockContextEventLoggerProxy.new
      allow(logger).to receive(:handle_event).and_call_original
      logger
    end

    let(:variable_parser) { DefaultVariableParser.new }
    let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }

    def client_mock
      client = instance_double(Client)
      allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
      allow(client).to receive(:publish).and_return(OpenStruct.new(success?: true))
      client
    end

    def create_ready_context
      config = ContextConfig.create
      config.set_units(units)

      Absmartly.create_context(config)
    end

    after do
      Absmartly.endpoint = nil
      Absmartly.api_key = nil
      Absmartly.application = nil
      Absmartly.environment = nil
      Absmartly.event_logger = nil
      Absmartly.instance_variable_set(:@sdk, nil)
      Absmartly.instance_variable_set(:@sdk_config, nil)
    end

    context "when configured globally" do
      before do
        allow(Client).to receive(:create).and_return(client_mock)

        Absmartly.configure_client do |config|
          config.endpoint = "https://test.absmartly.io/v1"
          config.api_key = "test-key"
          config.application = "test-app"
          config.environment = "test"
          config.event_logger = mock_logger
        end
      end

      it "receives READY event on context creation" do
        mock_logger.clear
        create_ready_context
        expect(mock_logger).to have_received(:handle_event)
          .with(ContextEventLogger::EVENT_TYPE::READY, data).once
      end

      it "receives EXPOSURE event with correct values when treatment() is called" do
        mock_logger.clear
        context = create_ready_context
        mock_logger.clear

        context.treatment("exp_test_ab")

        expect(mock_logger).to have_received(:handle_event)
          .with(ContextEventLogger::EVENT_TYPE::EXPOSURE, satisfy { |exposure|
            exposure.id == 1 &&
            exposure.name == "exp_test_ab" &&
            exposure.unit == "session_id" &&
            exposure.variant == 1 &&
            exposure.assigned == true &&
            exposure.eligible == true &&
            exposure.overridden == false &&
            exposure.full_on == false &&
            exposure.custom == false &&
            exposure.audience_mismatch == false
          }).once
      end

      it "receives GOAL event with correct values when track() is called" do
        mock_logger.clear
        context = create_ready_context
        mock_logger.clear

        properties = { amount: 125, hours: 245 }
        context.track("goal1", properties)

        expect(mock_logger).to have_received(:handle_event)
          .with(ContextEventLogger::EVENT_TYPE::GOAL, satisfy { |goal|
            goal.name == "goal1" &&
            goal.properties == properties
          }).once
      end

      it "receives PUBLISH event when publish() is called" do
        mock_logger.clear
        context = create_ready_context
        context.track("goal1", { amount: 125 })
        mock_logger.clear

        context.publish

        expect(mock_logger).to have_received(:handle_event)
          .with(ContextEventLogger::EVENT_TYPE::PUBLISH, instance_of(PublishEvent)).once
      end

      it "receives CLOSE event when close() is called" do
        mock_logger.clear
        context = create_ready_context
        mock_logger.clear

        context.close

        expect(mock_logger).to have_received(:handle_event)
          .with(ContextEventLogger::EVENT_TYPE::CLOSE, nil).once
      end
    end
  end
end
