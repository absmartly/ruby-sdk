# frozen_string_literal: true

require "time"
require_relative "context"
require_relative "audience_matcher"
require_relative "default_context_data_provider"
require_relative "default_context_event_handler"
require_relative "default_variable_parser"
require_relative "default_audience_deserializer"
require_relative "scheduled_thread_pool_executor"
require_relative "client_config"
require_relative "client"

class ABSmartly
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :audience_deserializer, :client

  def self.create(config)
    ABSmartly.new(config)
  end

  def self.new(config_or_endpoint = nil,
               api_key: nil,
               application: nil,
               environment: nil,
               timeout: nil,
               retries: nil,
               context_event_logger: nil)
    if config_or_endpoint.is_a?(ABSmartlyConfig)
      allocate.tap { |instance| instance.send(:initialize_from_config, config_or_endpoint) }
    else
      allocate.tap { |instance|
        instance.send(:initialize_from_params,
          config_or_endpoint,
          api_key,
          application,
          environment,
          timeout,
          retries,
          context_event_logger
        )
      }
    end
  end

  private

  def initialize_from_config(config)
    @context_data_provider = config.context_data_provider
    @context_event_handler = config.context_event_handler
    @context_event_logger = config.context_event_logger
    @variable_parser = config.variable_parser
    @audience_deserializer = config.audience_deserializer
    @scheduler = config.scheduler

    if @context_data_provider.nil? || @context_event_handler.nil?
      @client = config.client
      raise ArgumentError.new("Missing Client instance configuration") if @client.nil?

      if @context_data_provider.nil?
        @context_data_provider = DefaultContextDataProvider.new(@client)
      end

      if @context_event_handler.nil?
        @context_event_handler = DefaultContextEventHandler.new(@client)
      end
    end

    if @variable_parser.nil?
      @variable_parser = DefaultVariableParser.new
    end

    if @audience_deserializer.nil?
      @audience_deserializer = DefaultAudienceDeserializer.new
    end
    if @scheduler.nil?
      @scheduler = ScheduledThreadPoolExecutor.new(1)
    end
  end

  def initialize_from_params(endpoint, api_key, application, environment, timeout, retries, event_logger)
    raise ArgumentError.new("Missing required parameter: endpoint") if endpoint.nil? || endpoint.to_s.strip.empty?
    raise ArgumentError.new("Missing required parameter: api_key") if api_key.nil? || api_key.to_s.strip.empty?
    raise ArgumentError.new("Missing required parameter: application") if application.nil? || application.to_s.strip.empty?
    raise ArgumentError.new("Missing required parameter: environment") if environment.nil? || environment.to_s.strip.empty?

    timeout ||= 3000
    retries ||= 5

    raise ArgumentError.new("timeout must be a positive number") if timeout.to_i <= 0
    raise ArgumentError.new("retries must be a non-negative number") if retries.to_i < 0

    client_config = ClientConfig.create
    client_config.endpoint = endpoint
    client_config.api_key = api_key
    client_config.application = application
    client_config.environment = environment
    client_config.connect_timeout = timeout.to_f / 1000.0
    client_config.connection_request_timeout = timeout.to_f / 1000.0
    client_config.max_retries = retries

    @client = Client.create(client_config)
    @context_data_provider = DefaultContextDataProvider.new(@client)
    @context_event_handler = DefaultContextEventHandler.new(@client)
    @context_event_logger = event_logger
    @variable_parser = DefaultVariableParser.new
    @audience_deserializer = DefaultAudienceDeserializer.new
    @scheduler = ScheduledThreadPoolExecutor.new(1)
  end

  public

  def create_context(config)
    validate_params(config)
    Context.create(get_utc_format, config, @context_data_provider.context_data,
                   @context_data_provider, @context_event_handler, @context_event_logger, @variable_parser,
                   AudienceMatcher.new(@audience_deserializer))
  end

  def create_context_with(config, data)
    validate_params(config)
    Context.create(get_utc_format, config, data,
                   @context_data_provider, @context_event_handler, @context_event_logger, @variable_parser,
                   AudienceMatcher.new(@audience_deserializer))
  end

  def context_data
    @context_data_provider.context_data
  end

  private
    def get_utc_format
      Time.now.utc.iso8601(3)
    end

    def validate_params(params)
      params.units.each do |key, value|
        unless value.is_a?(String) || value.is_a?(Numeric)
          raise ArgumentError.new("Unit '#{key}' UID is of unsupported type '#{value.class}'. UID must be one of ['string', 'number']")
        end

        if value.to_s.size.zero?
          raise ArgumentError.new("Unit '#{key}' UID length must be >= 1")
        end
      end
    end
end

SDK = ABSmartly
