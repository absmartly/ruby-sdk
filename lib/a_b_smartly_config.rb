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

  def scheduler=(scheduler)
    @scheduler = scheduler
    self
  end

  def context_event_logger=(context_event_logger)
    @context_event_logger = context_event_logger
    self
  end

  def audience_deserializer=(audience_deserializer)
    @audience_deserializer = audience_deserializer
    self
  end

  def client=(client)
    @client = client
    self
  end
end
