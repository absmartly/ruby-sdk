# frozen_string_literal: true

class Context
  attr_accessor :context_data_provider, :context_event_handler,
                :variable_parser, :scheduler, :context_event_logger,
                :audience_deserializer, :client, :clock, :publish_delay,
                :refresh_interval

  def self.create(clock, config, scheduler, data_future, data_provider,
                  event_handler, event_logger, variable_parser, audience_matcher)
    Context.new(clock, config, scheduler, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher)
  end

  def initialize(clock, config, scheduler, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
    @clock = clock
    @publish_delay = config.getPublishDelay()
    @refresh_interval = config.getRefreshInterval()
    @event_handler = event_handler
    @event_logger = !config.event_logger.nil? ? config.event_logger : event_logger
    @data_provider = data_provider
    @variable_parser = variable_parser
    @audience_matcher = audience_matcher
    @scheduler = scheduler

    @units = {}

    units = config.units()
    @units = units unless units.nil?

    @assigners = {}
    @hashed_units = {}

    attributes = config.attributes
    @attributes = attributes unless attributes.nil?

    overrides = config.overrides
    @overrides = overrides { }

    cassignments = config.custom_assignments
    @cassignments = cassignments || {}
  end
end
