# frozen_string_literal: true

require "time"
require_relative "context"
require_relative "audience_matcher"
require_relative "default_context_data_provider"
require_relative "default_context_publisher"
require_relative "context_event_handler"
require_relative "default_context_event_handler"
require_relative "default_variable_parser"
require_relative "default_audience_deserializer"
require_relative "scheduled_thread_pool_executor"
require_relative "client_config"
require_relative "client"
require_relative "context_data_result"

class ABSmartly
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :audience_deserializer, :client

  def self.create(config)
    ABSmartly.new(config)
  end

  OPTIONS = %i[api_key application environment timeout retries context_event_logger].freeze

  # Accepts either a config object (ABSmartlyConfig or anything that responds
  # like it) or an endpoint String with keyword options. Options are read from
  # *args rather than keyword parameters so that Ruby 2.7 doesn't splat a
  # config that responds to to_hash into keywords.
  def initialize(*args)
    options = args.size > 1 && args.last.is_a?(Hash) ? args.pop : {}
    options = args.pop if args.size == 1 && args.first.instance_of?(Hash)
    raise ArgumentError.new("wrong number of arguments (given #{args.size}, expected 0..1)") if args.size > 1

    config_or_endpoint = args.first
    if config_or_endpoint.nil? || config_or_endpoint.is_a?(String)
      unknown = options.keys - OPTIONS
      raise ArgumentError.new("unknown keyword#{'s' if unknown.size > 1}: #{unknown.map(&:inspect).join(', ')}") unless unknown.empty?

      initialize_from_params(config_or_endpoint, *options.values_at(*OPTIONS))
    else
      initialize_from_config(config_or_endpoint)
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

      # Keep the configured client even when both custom providers are supplied,
      # so audience evaluation can still seed the application/environment names.
      @client = config.client

      if @context_data_provider.nil? || @context_event_handler.nil?
        raise ArgumentError.new("Missing Client instance configuration") if @client.nil?

        if @context_data_provider.nil?
          @context_data_provider = DefaultContextDataProvider.new(@client)
        end

        if @context_event_handler.nil?
          @context_event_handler = DefaultContextPublisher.new(@client)
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

      timeout = parse_number(timeout || 3000, "timeout") { |value| Float(value) }
      retries = parse_number(retries || 5, "retries") { |value| value.is_a?(Float) ? Integer(value.to_s) : Integer(value) }

      raise ArgumentError.new("timeout must be a positive number") if timeout <= 0
      raise ArgumentError.new("retries must be a non-negative number") if retries < 0

      client_config = ClientConfig.create
      client_config.endpoint = endpoint
      client_config.api_key = api_key
      client_config.application = application
      client_config.environment = environment
      client_config.connect_timeout = timeout / 1000.0
      client_config.connection_request_timeout = timeout / 1000.0
      client_config.max_retries = retries

      @client = Client.create(client_config)
      @context_data_provider = DefaultContextDataProvider.new(@client)
      @context_event_handler = DefaultContextPublisher.new(@client)
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
                   AudienceMatcher.new(@audience_deserializer),
                   application: client_application, environment: client_environment)
  end

  def create_context_async(config)
    validate_params(config)
    context = Context.create_async(get_utc_format, config, @context_data_provider,
                                   @context_event_handler, @context_event_logger, @variable_parser,
                                   AudienceMatcher.new(@audience_deserializer),
                                   application: client_application, environment: client_environment)
    data_provider = @context_data_provider
    Thread.new do
      data_future = data_provider.context_data
      context.set_data(data_future)
    rescue => e
      context.set_data(ContextDataResult.failure(e))
    end
    context
  end

  def create_context_with(config, data)
    validate_params(config)
    Context.create(get_utc_format, config, data,
                   @context_data_provider, @context_event_handler, @context_event_logger, @variable_parser,
                   AudienceMatcher.new(@audience_deserializer),
                   application: client_application, environment: client_environment)
  end

  def context_data
    @context_data_provider.context_data
  end

  private
    def get_utc_format
      Time.now.utc.iso8601(3)
    end

    # The application and environment names configured on the client seed the
    # audience evaluation map (the collector adds them server-side for publish).
    # Custom data providers may leave @client nil, so guard the reads.
    def client_application
      @client.application if @client.respond_to?(:application)
    end

    def client_environment
      @client.environment if @client.respond_to?(:environment)
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

    def parse_number(value, name)
      yield value
    rescue ArgumentError, TypeError
      raise ArgumentError.new("#{name} must be a number")
    end
end
