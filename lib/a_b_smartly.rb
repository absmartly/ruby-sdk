# frozen_string_literal: true

require_relative "default_context_data_provider"
require_relative "default_context_event_handler"
require_relative "default_variable_parser"
require_relative "default_audience_deserializer"
require_relative "scheduled_thread_pool_executor"

class ABSmartly
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :audience_deserializer, :client

  def self.create(config)
    ABSmartly.new(config)
  end

  def initialize(config)
    @context_data_provider = config.context_data_provider
    @context_event_handler = config.context_event_handler
    @context_event_logger = config.context_event_logger
    @variable_parser = config.variable_parser
    @audience_deserializer = config.audience_deserializer
    @scheduler = config.scheduler

    if @context_data_provider.nil? || context_event_handler.nil?
      @client = config.client
      raise ArgumentError.new("Missing Client instance") if @client.nil?

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

  def context_data_provider=(context_data_provider)
    @context_data_provider = context_data_provider
    self
  end

  attr_reader :context_data_provider

  def context_event_handler=(context_event_handler)
    @context_event_handler = context_event_handler
    self
  end

  def context_data_provide
    @context_event_handler
  end

  def variable_parser=(variable_parser)
    @variable_parser = variable_parser
    self
  end

  attr_reader :variable_parser

  def scheduler=(scheduler)
    @scheduler = scheduler
    self
  end

  attr_reader :scheduler

  def context_event_logger=(context_event_logger)
    @context_event_logger = context_event_logger
    self
  end

  attr_reader :context_event_logger

  def client=(client)
    @client = client
    self
  end

  attr_reader :client
end
