# frozen_string_literal: true

require "forwardable"
require_relative "default_context_data_deserializer"
require_relative "default_context_event_serializer"
require_relative "default_http_client_config"

class ClientConfig
  extend Forwardable

  attr_accessor :endpoint, :api_key, :environment, :application

  attr_reader :http_client_config

  attr_writer :context_data_deserializer, :context_event_serializer

  def_delegators :@http_client_config, :connect_timeout, :connection_request_timeout, :retry_interval, :max_retries

  def self.create(endpoint: nil, environment: nil, application: nil, api_key: nil)
    new(endpoint:, environment:, application:, api_key:)
  end

  def self.create_from_properties(properties, prefix)
    properties = properties.transform_keys(&:to_sym)
    create(
      endpoint: properties["#{prefix}endpoint".to_sym],
      environment: properties["#{prefix}environment".to_sym],
      application: properties["#{prefix}application".to_sym],
      api_key: properties["#{prefix}apikey".to_sym]
    )
  end

  def initialize(endpoint: nil, environment: nil, application: nil, api_key: nil)
    @endpoint = endpoint
    @environment = environment
    @application = application
    @api_key = api_key

    @http_client_config = DefaultHttpClientConfig.new
  end

  def context_data_deserializer
    @context_data_deserializer ||= DefaultContextDataDeserializer.new
  end

  def context_event_serializer
    @context_event_serializer ||= DefaultContextEventSerializer.new
  end

  def deserializer=(deserializer)
    @context_data_deserializer = deserializer
  end

  def serializer=(serializer)
    @context_event_serializer = serializer
  end

  def deserializer
    context_data_deserializer
  end

  def serializer
    context_event_serializer
  end

  def url
    @url ||= "#{endpoint}/context"
  end

  def headers
    @headers ||= {
      "Content-Type": "application/json",
      "X-API-Key": api_key,
      "X-Application": application,
      "X-Environment": environment,
      "X-Application-Version": "0",
      "X-Agent": "absmartly-ruby-sdk"
    }
  end

  def query
    @query ||= {
      "application": application,
      "environment": environment
    }
  end

  def validate!
    raise ArgumentError.new("Missing Endpoint configuration") if endpoint.nil? || endpoint.empty?
    raise ArgumentError.new("Missing APIKey configuration") if api_key.nil? || api_key.empty?
    raise ArgumentError.new("Missing Application configuration") if application.nil? || application.empty?
    raise ArgumentError.new("Missing Environment configuration") if environment.nil? || environment.empty?
  end
end
