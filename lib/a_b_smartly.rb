# frozen_string_literal: true

require "time"
require_relative "context"
require_relative "audience_matcher"
require_relative "default_context_data_provider"
require_relative "default_context_event_handler"
require_relative "default_variable_parser"
require_relative "default_audience_deserializer"
require_relative "scheduled_thread_pool_executor"

class ABSmartly
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :audience_deserializer, :client

  def self.configure_client(&block)
    @@init_http = block
  end

  def self.create(config)
    ABSmartly.new(config)
  end

  def initialize(config)
    @@init_http = nil
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

  def create_context(config)
    validate_params(config)
    Context.create(get_utc_format, config, @context_data_provider.context_data,
                   @context_data_provider, @context_event_handler, @context_event_logger, @variable_parser,
                   AudienceMatcher.new(@audience_deserializer))
  end

  def create_context_with(config, data)
    Context.create(get_utc_format, config, scheduler, data,
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
