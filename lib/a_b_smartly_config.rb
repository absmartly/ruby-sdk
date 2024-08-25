# frozen_string_literal: true

require "forwardable"

require_relative "client"
require_relative "client_config"
require_relative "default_context_data_provider"
require_relative "default_context_event_handler"
require_relative "default_variable_parser"
require_relative "default_audience_deserializer"

class ABSmartlyConfig
  extend Forwardable

  attr_accessor :scheduler

  attr_writer :context_data_provider, :context_event_handler, :audience_deserializer, :variable_parser, :client

  attr_reader :client_config, :context_event_logger

  def_delegators :@client_config, :endpoint, :api_key, :application, :environment
  def_delegators :@client_config, :connect_timeout, :connection_request_timeout, :retry_interval, :max_retries

  def self.create
    new
  end

  def initialize
    @client_config = ClientConfig.new
  end

  def validate!
    raise ArgumentError.new("event logger not configured") if context_event_logger.nil?
    raise ArgumentError.new("failed to initialize client") if client.nil?
    raise ArgumentError.new("failed to initialize context_data_provider") if context_data_provider.nil?
  end

  def context_event_logger=(context_event_logger)
    if context_event_logger.is_a?(Proc)
      @context_event_logger = ContextEventLoggerCallback.new(context_event_logger)
    else
      @context_event_logger = context_event_logger
    end
  end

  def variable_parser
    @variable_parser ||= DefaultVariableParser.new
  end

  def audience_deserializer
    @audience_deserializer ||= DefaultAudienceDeserializer.new
  end

  def context_data_provider
    @context_data_provider ||= DefaultContextDataProvider.new(client)
  end

  def context_event_handler
    @context_event_handler ||= DefaultContextEventHandler.new(client)
  end

  def client
    @client ||= Client.new(client_config)
  end
end
