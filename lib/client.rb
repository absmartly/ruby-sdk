# frozen_string_literal: true

require_relative "default_http_client"
require_relative "default_context_data_deserializer"
require_relative "default_context_event_serializer"

class Client
  attr_accessor :url, :query, :http_client, :executor, :deserializer, :serializer
  attr_reader :data_future, :promise, :exception

  def self.create(config, http_client = nil)
    Client.new(config, http_client || DefaultHttpClient.create(config.http_client_config))
  end

  def initialize(config, http_client = nil)
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
      "Content-Type": "application/json",
      "X-API-Key": api_key,
      "X-Application": application,
      "X-Environment": environment,
      "X-Application-Version": "0",
      "X-Agent": "absmartly-ruby-sdk"
    }

    @query = {
      "application": application,
      "environment": environment
    }
  end

  def context_data
    @promise = @http_client.get(@url, @query, @headers)
    unless @promise.success?
      @exception = Exception.new(@promise.body)
      warn("Failed to fetch context data: #{@promise.body}")
      return self
    end

    content = (@promise.body || {}).to_s
    @data_future = @deserializer.deserialize(content, 0, content.size)
    self
  end

  def publish(event)
    content = @serializer.serialize(event)
    response = @http_client.put(@url, nil, @headers, content)

    unless response.success?
      error = Exception.new(response.body)
      warn("Publish failed: #{response.body}")
      return error
    end

    response
  end

  def close
    @http_client.close
  end

  def success?
    @promise&.success? || false
  end

  def inspect
    "#<Client url=#{@url.inspect}>"
  end

  private

  attr_reader :headers
end
