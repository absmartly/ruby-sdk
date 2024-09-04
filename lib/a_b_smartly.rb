# frozen_string_literal: true

require "time"
require "singleton"
require "forwardable"
require_relative "context"
require_relative "audience_matcher"
require_relative "a_b_smartly_config"
require_relative "absmartly/version"

class ABSmartly
  extend Forwardable

  attr_reader :config

  def_delegators :@config, :context_data_provider, :context_event_handler, :variable_parser, :context_event_logger,
                 :audience_deserializer, :client

  def_delegators :@config, :endpoint, :api_key, :application, :environment

  def self.create(config)
    new(config)
  end

  def initialize(config)
    config.validate!

    @config = config
  end

  def create_context(context_config)
    Context.create(get_utc_format, context_config, context_data,
                   context_data_provider, context_event_handler, context_event_logger, variable_parser,
                   AudienceMatcher.new(audience_deserializer))
  end

  def create_context_with(context_config, data)
    Context.create(get_utc_format, context_config, data,
                   context_data_provider, context_event_handler, context_event_logger, variable_parser,
                   AudienceMatcher.new(audience_deserializer))
  end

  def context_data
    context_data_provider.context_data
  end

  private
    def get_utc_format
      Time.now.utc.iso8601(3)
    end
end
