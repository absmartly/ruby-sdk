# frozen_string_literal: true

require "client_config"
require "context_data_deserializer"
require "context_event_serializer"
require "default_http_client_config"

RSpec.describe ClientConfig do
  it ".endpoint" do
    config = described_class.create
    config.endpoint = "https://test.endpoint.com"
    expect(config.endpoint).to eq("https://test.endpoint.com")
  end

  it ".api_key" do
    config = described_class.create
    config.api_key = "api-key-test"
    expect(config.api_key).to eq("api-key-test")
  end

  it ".environment" do
    config = described_class.create
    config.environment = "test"
    expect(config.environment).to eq("test")
  end

  it ".application" do
    config = described_class.create
    config.application = "website"
    expect(config.application).to eq("website")
  end

  it ".context_data_deserializer" do
    deserializer = instance_double(ContextDataDeserializer)
    config = described_class.create
    config.context_data_deserializer = deserializer
    expect(config.context_data_deserializer).to eq(deserializer)
  end

  it ".context_event_serializer" do
    serializer = instance_double(ContextEventSerializer)
    config = described_class.create
    config.context_event_serializer = serializer
    expect(config.context_event_serializer).to eq(serializer)
  end

  it ".executor" do
    deserializer = instance_double(ContextDataDeserializer)
    serializer = instance_double(ContextEventSerializer)
    config = described_class.create
    config.endpoint = "https://test.endpoint.com"
    config.api_key = "api-key-test"
    config.environment = "test"
    config.application = "website"
    config.context_data_deserializer = deserializer
    config.context_event_serializer = serializer
    expect(config.endpoint).to eq("https://test.endpoint.com")
    expect(config.api_key).to eq("api-key-test")
    expect(config.environment).to eq("test")
    expect(config.application).to eq("website")
    expect(config.context_data_deserializer).to eq(deserializer)
    expect(config.context_event_serializer).to eq(serializer)
  end

  it ".create_from_properties" do
    props = {
      "absmartly.endpoint": "https://test.endpoint.com",
      "absmartly.environment": "test",
      "absmartly.apikey": "api-key-test",
      "absmartly.application": "website"
    }

    deserializer = instance_double(ContextDataDeserializer)
    serializer = instance_double(ContextEventSerializer)
    config = described_class.create_from_properties(props, "absmartly.")
    config.context_data_deserializer = deserializer
    config.context_event_serializer = serializer
    expect(config.api_key).to eq("api-key-test")
    expect(config.environment).to eq("test")
    expect(config.application).to eq("website")
    expect(config.context_data_deserializer).to eq(deserializer)
    expect(config.context_event_serializer).to eq(serializer)
  end

  it ".connect_timeout" do
    config = described_class.create
    config.connect_timeout = 5.0
    expect(config.connect_timeout).to eq(5.0)
  end

  it ".connection_request_timeout" do
    config = described_class.create
    config.connection_request_timeout = 10.0
    expect(config.connection_request_timeout).to eq(10.0)
  end

  it ".retry_interval" do
    config = described_class.create
    config.retry_interval = 1.0
    expect(config.retry_interval).to eq(1.0)
  end

  it ".max_retries" do
    config = described_class.create
    config.max_retries = 3
    expect(config.max_retries).to eq(3)
  end

  describe ".http_client_config" do
    it "returns DefaultHttpClientConfig with custom values" do
      config = described_class.create
      config.connect_timeout = 5.0
      config.connection_request_timeout = 10.0
      config.retry_interval = 1.0
      config.max_retries = 3

      http_config = config.http_client_config
      expect(http_config).to be_a(DefaultHttpClientConfig)
      expect(http_config.connect_timeout).to eq(5.0)
      expect(http_config.connection_request_timeout).to eq(10.0)
      expect(http_config.retry_interval).to eq(1.0)
      expect(http_config.max_retries).to eq(3)
    end

    it "returns DefaultHttpClientConfig with defaults when options not set" do
      config = described_class.create

      http_config = config.http_client_config
      expect(http_config).to be_a(DefaultHttpClientConfig)
      expect(http_config.connect_timeout).to eq(3.0)
      expect(http_config.connection_request_timeout).to eq(3.0)
      expect(http_config.retry_interval).to eq(0.5)
      expect(http_config.max_retries).to eq(5)
    end
  end
end
