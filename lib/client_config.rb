# frozen_string_literal: true

require_relative "default_http_client_config"

class ClientConfig
  attr_accessor :endpoint, :api_key, :environment, :application, :deserializer,
                :serializer, :executor, :connect_timeout, :connection_request_timeout,
                :retry_interval, :max_retries

  def self.create
    ClientConfig.new
  end

  def self.create_from_properties(properties, prefix)
    properties = properties.transform_keys(&:to_sym)
    client_config = create
    client_config.endpoint = properties["#{prefix}endpoint".to_sym]
    client_config.environment = properties["#{prefix}environment".to_sym]
    client_config.application = properties["#{prefix}application".to_sym]
    client_config.api_key = properties["#{prefix}apikey".to_sym]
    client_config
  end

  def initialize(endpoint: nil, environment: nil, application: nil, api_key: nil)
    @endpoint = endpoint
    @environment = environment
    @application = application
    @api_key = api_key
  end

  def context_data_deserializer
    @deserializer
  end

  def context_data_deserializer=(deserializer)
    @deserializer = deserializer
  end

  def context_event_serializer
    @serializer
  end

  def context_event_serializer=(serializer)
    @serializer = serializer
  end

  def http_client_config
    http_config = DefaultHttpClientConfig.create
    http_config.connect_timeout = @connect_timeout unless @connect_timeout.nil?
    http_config.connection_request_timeout = @connection_request_timeout unless @connection_request_timeout.nil?
    http_config.retry_interval = @retry_interval unless @retry_interval.nil?
    http_config.max_retries = @max_retries unless @max_retries.nil?
    http_config
  end
end
