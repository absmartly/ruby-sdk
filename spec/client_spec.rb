# frozen_string_literal: true

require "client"
require "client_config"
require "json/context_data"
require "json/publish_event"
require "context_data_deserializer"
require "context_event_serializer"
require "http_client"
require "default_http_client"
require "default_context_data_deserializer"
require "default_context_event_serializer"

RSpec.describe Client do
  it "create throws with invalid config" do
    expect {
      config = ClientConfig.create
      config.api_key = "test-api-key"
      config.application = "website"
      config.environment = "dev"
      Client.create(config)
    }.to raise_error(ArgumentError, "Missing Endpoint configuration")

    expect {
      config = ClientConfig.create
      config.endpoint = "https://localhost/v1"
      config.application = "website"
      config.environment = "dev"
      Client.create(config)
    }.to raise_error(ArgumentError, "Missing APIKey configuration")

    expect {
      config = ClientConfig.create
      config.endpoint = "https://localhost/v1"
      config.api_key = "test-api-key"
      config.environment = "dev"
      Client.create(config)
    }.to raise_error(ArgumentError, "Missing Application configuration")

    expect {
      config = ClientConfig.create
      config.endpoint = "https://localhost/v1"
      config.api_key = "test-api-key"
      config.application = "website"
      Client.create(config)
    }.to raise_error(ArgumentError, "Missing Environment configuration")
  end

  xit "create with defaults" do
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"

    data_bytes = "{}"
    expected = ContextData.new

    event = PublishEvent.new
    publish_bytes = nil

    deser_ctor = instance_double(DefaultContextDataDeserializer)
    allow(deser_ctor).to receive(:deserialize).with(data_bytes, 0, data_bytes.length).and_return(expected)
    deser_ctor.deserialize(data_bytes, 0, data_bytes.length)

    ser_ctor = instance_double(DefaultContextEventSerializer)
    allow(ser_ctor).to receive(:serialize).with(event).and_return(publish_bytes)
    ser_ctor.serialize(event)

    http_client = instance_double(DefaultHttpClient)
    allow(DefaultHttpClient).to receive(:create).and_return(http_client)

    expected_query = {
      "application": "website",
      "environment": "dev"
    }

    expected_headers = {
      "X-API-Key": "test-api-key",
      "X-Application": "website",
      "X-Environment": "dev",
      "X-Application-Version": "0",
      "X-Agent": "absmartly-java-sdk"
    }

    allow(ser_ctor).to receive(:serialize).with(event).and_return(publish_bytes)

    allow(http_client).to receive(:get).with("https://localhost/v1/context", expected_query, nil).and_return(byte_response(data_bytes))
    allow(http_client).to receive(:put).with("https://localhost/v1/context", nil, expected_headers, publish_bytes).and_return(byte_response(data_bytes))
    allow(http_client).to receive(:close)

    client = Client.create(config)
    client.context_data

    client.publish(event)

    expect {
      client.close
    }.not_to raise_error
    expect(http_client).to have_received(:get).with("https://localhost/v1/context", expected_query, nil).once
    expect(http_client).to have_received(:put).with("https://localhost/v1/context", nil, expected_headers, publish_bytes).once
    expect(http_client).to have_received(:close).once

    expect(deser_ctor).to have_received(:deserialize).once
    expect(deser_ctor).to have_received(:deserialize).with(data_bytes, 0, data_bytes.length).once

    expect(ser_ctor).to have_received(:serialize).once
    expect(ser_ctor).to have_received(:serialize).with(event).once
  end

  xit "context_data" do
    http_client = HttpClient.new
    deser = ContextDataDeserializer.new
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_data_deserializer = deser
    client = Client.create(config, http_client)

    data_bytes = "{}"

    expected_query = {
      "application": "website",
      "environment": "dev"
    }

    allow(http_client).to receive(:get).with("https://localhost/v1/context", expected_query, nil).and_return(byte_response(data_bytes))

    expected = ContextData.new
    allow(deser).to receive(:deserialize).with(data_bytes, 0, data_bytes.size).and_return(expected)

    data_future = client.context_data
    actual = data_future

    expect(actual).to eq(expected)
  end

  xit "context data exceptionally HTTP" do
    http_client = instance_double(HttpClient)
    deser = instance_double(ContextDataDeserializer)
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_data_deserializer = deser

    client = Client.create(config, http_client)

    expected_query = {
      "application": "website",
      "environment": "dev"
    }

    allow(deser).to receive(:deserialize).and_return({})
    allow(http_client).to receive(:get).with("https://localhost/v1/context", expected_query, nil)
                                       .and_return(DefaultHttpClient.default_response(500, "Internal Server Error", nil, nil))

    data_future = client.context_data
    actual = data_future
    expect(actual.message).to eq("Internal Server Error")
    expect(http_client).to have_received(:get).with("https://localhost/v1/context", expected_query, nil).once
    expect(deser).to have_received(:deserialize).exactly(0).time
  end

  xit "context data exceptionally connection" do
    http_client = instance_double(HttpClient)
    deser = instance_double(ContextDataDeserializer)
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_data_deserializer = deser

    client = Client.create(config, http_client)

    expected_query = {
      "application": "website",
      "environment": "dev"
    }

    response_future = failed_response(content: "FAILED")
    allow(deser).to receive(:deserialize).and_return({})
    allow(http_client).to receive(:get).with("https://localhost/v1/context", expected_query, nil)
                                       .and_return(response_future)
    data_future = client.context_data
    actual = data_future
    expect(actual).to eq(Exception.new("FAILED"))
    expect(http_client).to have_received(:get).with("https://localhost/v1/context", expected_query, nil).once
    expect(deser).to have_received(:deserialize).exactly(0).time
  end

  it "publish" do
    http_client = instance_double(HttpClient)
    ser = instance_double(ContextEventSerializer)
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_event_serializer = ser

    client = Client.create(config, http_client)
    expected_headers = {
      "X-API-Key": "test-api-key",
      "X-Application": "website",
      "X-Environment": "dev",
      "X-Application-Version": "0",
      "X-Agent": "absmartly-java-sdk"
    }
    bytes = "0"
    event = PublishEvent.new
    allow(ser).to receive(:serialize).with(event).and_return(bytes)
    allow(http_client).to receive(:put).with("https://localhost/v1/context", nil, expected_headers, bytes)
                                       .and_return(byte_response(bytes[0]))
    client.publish(event)

    expect(ser).to have_received(:serialize).with(event).once
    expect(http_client).to have_received(:put).once
    expect(http_client).to have_received(:put).with("https://localhost/v1/context", nil, expected_headers, bytes).once
  end

  it "publish Exceptionally HTTP" do
    http_client = instance_double(HttpClient)
    ser = instance_double(ContextEventSerializer)
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_event_serializer = ser
    client = Client.create(config, http_client)

    expected_headers = {
      "X-API-Key": "test-api-key",
      "X-Application": "website",
      "X-Environment": "dev",
      "X-Application-Version": "0",
      "X-Agent": "absmartly-java-sdk"
    }
    event = PublishEvent.new
    bytes = "0"

    allow(ser).to receive(:serialize).with(event).and_return(bytes)
    allow(http_client).to receive(:put).with("https://localhost/v1/context", nil, expected_headers, bytes)
                                       .and_return(DefaultHttpClient.default_response(500, "Internal Server Error", nil, nil))
    client.publish(event)
    expect(http_client).to have_received(:put).once
    expect(http_client).to have_received(:put).with("https://localhost/v1/context", nil, expected_headers, bytes).once
  end

  it "publish Exceptionally Connection" do
    http_client = instance_double(HttpClient)
    ser = instance_double(ContextEventSerializer)
    config = ClientConfig.create
    config.endpoint = "https://localhost/v1"
    config.api_key = "test-api-key"
    config.application = "website"
    config.environment = "dev"
    config.context_event_serializer = ser
    client = Client.create(config, http_client)

    expected_headers = {
      "X-API-Key": "test-api-key",
      "X-Application": "website",
      "X-Environment": "dev",
      "X-Application-Version": "0",
      "X-Agent": "absmartly-java-sdk"
    }
    event = PublishEvent.new
    bytes = "0"

    response_future = failed_response(content: "FAILED")
    allow(ser).to receive(:serialize).and_return(bytes)
    allow(http_client).to receive(:put).with("https://localhost/v1/context", nil, expected_headers, bytes)
                                       .and_return(response_future)
    publish_future = client.publish(event)
    actual = publish_future
    expect(actual).to eq(Exception.new("FAILED"))

    expect(ser).to have_received(:serialize).with(event).once
    expect(http_client).to have_received(:put).with("https://localhost/v1/context", nil, expected_headers, bytes).once
  end
end

def byte_response(bytes)
  DefaultHttpClient.default_response(
    200,
    "OK",
    "application/json; charset=utf8",
    bytes)
end

def failed_response(status_code: 400, status_message: "Bad Request", content: nil)
  DefaultHttpClient.default_response(
    status_code,
    status_message,
    "application/json; charset=utf8",
    content)
end
