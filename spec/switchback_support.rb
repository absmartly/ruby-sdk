# frozen_string_literal: true

require "json"
require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_context_event_serializer"
require "default_variable_parser"
require "hashing"
require "variant_assigner"
require "absmartly/switchback"

# Helpers shared by the switchback context specs (java-sdk SwitchbackTestSupport).
module SwitchbackSpecSupport
  HOUR = 3_600_000
  DAY = 24 * HOUR
  # 2026-01-01T00:00:00Z, hour aligned.
  ANCHOR = 1_767_225_600_000

  # bigdecimal is a bundled gem, not in the Gemfile, from Ruby 3.4.
  def self.big_decimal?
    return @big_decimal unless @big_decimal.nil?

    @big_decimal = begin
      verbose = $VERBOSE
      # Ruby 4.0 warns when a former default gem loads outside the bundle.
      $VERBOSE = nil
      require "bigdecimal"
      true
    rescue LoadError
      false
    ensure
      $VERBOSE = verbose
    end
  end

  # Reads `now`; when next_read is set, the next read returns it once.
  class MutableClock
    attr_accessor :now, :next_read

    def initialize(now)
      @now = now
    end

    def call
      unless @next_read.nil?
        value = @next_read
        @next_read = nil
        return value
      end
      @now
    end
  end

  class Publisher
    attr_reader :events

    def initialize
      @events = []
    end

    def publish(_context, event)
      @events << event
      OpenStruct.new(success?: true)
    end
  end

  class Logger
    attr_reader :exposures

    def initialize
      @exposures = []
    end

    def handle_event(type, data)
      @exposures << data if type == ContextEventLogger::EVENT_TYPE::EXPOSURE
    end
  end

  # Decodes through the SDK's own deserializer, as a fetched payload is.
  def data_of(experiments, holdouts = nil)
    payload = { experiments: experiments }
    payload[:holdouts] = holdouts unless holdouts.nil?
    json = JSON.generate(payload)
    DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
  end

  def ready(data)
    OpenStruct.new(data_future: data, success?: true)
  end

  def build_context(data, units:, attributes: {}, audience_matcher: nil, publisher: Publisher.new,
                    logger: nil, provider: nil, overrides: {}, custom: {})
    config = ContextConfig.create
    config.set_units(units)
    config.set_attributes(attributes) unless attributes.empty?
    config.set_overrides(overrides)
    config.set_custom_assignments(custom)
    Context.create(clock, config, ready(data), provider, publisher, logger, DefaultVariableParser.new,
                   audience_matcher || AudienceMatcher.new(DefaultAudienceDeserializer.new),
                   application: "website", environment: "production")
  end

  def published_exposures(context)
    publisher = context.send(:event_handler)
    before = publisher.events.length
    context.publish
    publisher.events[before..].flat_map { |event| event.exposures || [] }
  end

  def exposure(id, name, unit, variant, exposed_at, assigned, eligible, overridden = false, full_on = false,
               custom = false, audience_mismatch = false, rule_override = false)
    Exposure.new(id, name, unit, variant, exposed_at, assigned, eligible, overridden, full_on, custom,
                 audience_mismatch, rule_override)
  end

  def draw(key, period, seed_hi, seed_lo, arms)
    Absmartly::Switchback::Assigner.assign(key, period, (seed_hi << 32) | (seed_lo & 0xffffffff), arms)
  end
end
