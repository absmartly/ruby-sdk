# frozen_string_literal: true

require "client_config"
require "context_data_deserializer"
require "context_event_serializer"

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
end
