# frozen_string_literal: true

class ABSmartlyConfig
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :client, :audience_deserializer
  def self.create
    ABSmartlyConfig.new
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

  def audience_deserializer=(audience_deserializer)
    @audience_deserializer = audience_deserializer
    self
  end

  attr_reader :audience_deserializer

  def client=(client)
    @client = client
    self
  end

  attr_reader :client
end
