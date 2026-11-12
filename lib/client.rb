# frozen_string_literal: true

require_relative "absmartly/version"
require_relative "default_http_client"
require_relative "default_context_data_deserializer"
require_relative "default_context_event_serializer"
require_relative "context_data_result"
require_relative "publish_error"

class Client
  attr_accessor :url, :query, :headers, :http_client, :executor, :deserializer, :serializer
  attr_reader :data_future, :promise, :exception, :application, :environment

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
    @application = application
    @environment = environment
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
      "X-Agent": "absmartly-ruby-sdk/#{Absmartly::VERSION}"
    }

    @query = {
      "application": application,
      "environment": environment
    }
  end

  # Returns a ContextDataResult for this fetch. The data_future, exception
  # and promise readers on the client still mirror the latest fetch.
  def context_data
    result = fetch_context_data
    @promise = result.promise
    @exception = result.exception
    @data_future = result.data_future
    result
  end

  def publish(event)
    content = @serializer.serialize(event)
    response = @http_client.put(@url, nil, @headers, content)

    unless response.success?
      # A routine collector rejection must stay catchable with a normal
      # `rescue StandardError` when close/finalize raises it, so use a
      # StandardError subclass rather than Ruby's base Exception.
      return PublishError.new(response.body)
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
    def fetch_context_data
      begin
        promise = @http_client.get(@url, @query, @headers)
      rescue StandardError => e
        return ContextDataResult.failure(e)
      end

      unless promise.success?
        return ContextDataResult.failure(Exception.new(promise.body), promise)
      end

      content = (promise.body || {}).to_s
      data = @deserializer.deserialize(content, 0, content.size)
      return ContextDataResult.failure(StandardError.new("Failed to deserialize context data"), promise) if data.nil?

      ContextDataResult.new(data, nil, promise)
    end
end
