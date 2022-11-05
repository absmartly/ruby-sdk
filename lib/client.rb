# frozen_string_literal: true

require "byebug"
require "default_http_client"
require "default_http_client_config"
require "default_context_data_deserializer"
require "default_context_event_serializer"

class Client
  attr_accessor :url, :query, :headers, :http_client, :executor, :deserializer, :serializer

  def self.create(config, http_client = nil)
    Client.new(config, http_client || DefaultHttpClient.create(DefaultHttpClientConfig.create))
  end

  def initialize(config = nil, http_client = nil)
    endpoint = config.endpoint
    raise ArgumentError.new("Missing Endpoint configuration") if endpoint.nil? || endpoint.empty?

    api_key = config.api_key
    raise ArgumentError.new("Missing APIKey configuration") if api_key.nil? || api_key.empty?

    application = config.application
    raise ArgumentError.new("Missing Application configuration") if application.nil? || application.empty?

    environment = config.environment
    raise ArgumentError.new("Missing Environment configuration") if environment.nil? || environment.empty?

    @url = "#{endpoint}/context"
    @http_client = http_client
    @deserializer = config.context_data_deserializer
    @serializer = config.context_event_serializer
    @executor = config.executor

    @deserializer = DefaultContextDataDeserializer.new if @deserializer.nil?
    @serializer = DefaultContextEventSerializer.new if @serializer.nil?

    @headers = {
      "X-API-Key": api_key,
      "X-Application": application,
      "X-Environment": environment,
      "X-Application-Version": "0",
      "X-Agent": "absmartly-java-sdk"
    }

    @query = {
      "application": application,
      "environment": environment
    }
  end

  def context_data
    data_future = ContextData.new
    response = @http_client.get(@url, @query, nil)
    return Exception.new(response.body) unless response.success?

    content = (response.body || {}).to_s
    @deserializer.deserialize(content, 0, content.size)
    data_future
  end

  def publish(event)
    content = @serializer.serialize(event)
    response = @http_client.put(@url, nil, @headers, content)
    return Exception.new(response.body) unless response.success?

    response
  end

  def close
    @http_client.close
  end
end
