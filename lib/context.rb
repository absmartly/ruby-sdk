# frozen_string_literal: true

require_relative "hashing"
require_relative "variant_assigner"
require_relative "context_event_logger"
require_relative "json/unit"
require_relative "json/attribute"
require_relative "json/exposure"
require_relative "json/publish_event"
require_relative "json/goal_achievement"

class Context
  attr_reader :data, :pending_count

  def self.create(clock, config, data_future, data_provider,
                  event_handler, event_logger, variable_parser, audience_matcher)
    Context.new(clock, config, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher)
  end

  def initialize(clock, config, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
    @index = []
    @achievements = []
    @assignment_cache = {}
    @assignments = {}
    @clock = clock.is_a?(String) ? Time.iso8601(clock) : clock
    @publish_delay = config.publish_delay
    @refresh_interval = config.refresh_interval
    @event_handler = event_handler
    @event_logger = !config.event_logger.nil? ? config.event_logger : event_logger
    @data_provider = data_provider
    @variable_parser = variable_parser
    @audience_matcher = audience_matcher
    @closed = false

    @units = {}
    @attributes = []
    @overrides = {}
    @cassignments = {}
    @assigners = {}
    @hashed_units = {}
    @pending_count = 0
    @exposures ||= []

    set_units(config.units) if config.units
    set_attributes(config.attributes) if config.attributes
    set_overrides(config.overrides) if config.overrides
    set_custom_assignments(config.custom_assignments) if config.custom_assignments
    if data_future.success?
      assign_data(data_future.data_future)
      log_event(ContextEventLogger::EVENT_TYPE::READY, data_future.data_future)
    else
      set_data_failed(data_future.exception)
      log_error(data_future.exception)
    end
  end

  def ready?
    !@data.nil?
  end

  def failed?
    @failed
  end

  def closed?
    @closed
  end

  def experiments
    check_ready?(true)

    @data.experiments.map(&:name)
  end

  def set_override(experiment_name, variant)
    check_not_closed?

    @overrides[experiment_name.to_s.to_sym] = variant
  end

  def set_overrides(overrides)
    check_not_closed?

    @overrides.merge!(overrides.transform_keys(&:to_sym))
  end

  def override(experiment_name)
    check_not_closed?

    @overrides[experiment_name.to_s.to_sym]
  end

  def set_custom_assignment(experiment_name, variant)
    check_not_closed?

    @cassignments[experiment_name.to_s.to_sym] = variant
  end

  def set_custom_assignments(custom_assignments)
    check_not_closed?

    @cassignments.merge!(custom_assignments.transform_keys(&:to_sym))
  end

  def custom_assignment(experiment_name)
    check_not_closed?

    @cassignments[experiment_name.to_s.to_sym]
  end

  def set_unit(unit_type, uid)
    check_not_closed?

    previous = @units[unit_type.to_sym]
    if !previous.nil? && previous != uid
      raise IllegalStateException.new("Unit '#{unit_type}' already set.")
    end

    trimmed = uid.to_s.strip
    if trimmed.empty?
      raise IllegalStateException.new("Unit '#{unit_type}' UID must not be blank.")
    end

    @units[unit_type] = trimmed
  end

  def set_units(units)
    check_not_closed?

    units.each { |key, value| self.set_unit(key, value) }
  end

  def set_attribute(name, value)
    check_not_closed?

    @attributes.push(Attribute.new(name, value, @clock.to_i))
  end

  def set_attributes(attributes)
    check_not_closed?

    attributes.each { |key, value| self.set_attribute(key, value) }
  end

  def treatment(experiment_name)
    check_ready?(true)
    assignment = assignment(experiment_name)
    unless assignment.exposed
      queue_exposure(assignment)
    end

    assignment.variant
  end

  def queue_exposure(assignment)
    unless assignment.exposed
      assignment.exposed = true

      exposure = Exposure.new
      exposure.id = assignment.id || 0
      exposure.name = assignment.name
      exposure.unit = assignment.unit_type
      exposure.variant = assignment.variant
      exposure.exposed_at = @clock.to_i
      exposure.assigned = assignment.assigned
      exposure.eligible = assignment.eligible
      exposure.overridden = assignment.overridden
      exposure.full_on = assignment.full_on
      exposure.custom = assignment.custom
      exposure.audience_mismatch = assignment.audience_mismatch

      @pending_count += 1
      @exposures.push(exposure)
      log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposure)
    end
  end

  def peek_treatment(experiment_name)
    check_ready?(true)

    assignment(experiment_name).variant
  end

  def variable_keys
    check_ready?(true)

    hsh = {}
    @index_variables.each { |key, value| hsh[key] = value.data.name }
    hsh
  end

  def variable_value(key, default_value)
    check_ready?(true)

    assignment = variable_assignment(key)
    unless assignment.nil? || assignment.variables.nil?
      queue_exposure(assignment) unless assignment.exposed
      return assignment.variables[key.to_s.to_sym] if assignment.variables.key?(key.to_s.to_sym)
    end

    default_value
  end

  def peek_variable_value(key, default_value)
    check_ready?(true)

    assignment = variable_assignment(key)
    return assignment.variables[key.to_s.to_sym] if !assignment.nil? &&
      !assignment.variables.nil? &&
      assignment.variables.key?(key.to_s.to_sym)

    default_value
  end

  def track(goal_name, properties)
    check_not_closed?

    achievement = GoalAchievement.new
    achievement.achieved_at = @clock.to_i
    achievement.name = goal_name
    achievement.properties = properties

    @pending_count += 1
    @achievements.push(achievement)
    log_event(ContextEventLogger::EVENT_TYPE::GOAL, achievement)
  end

  def publish
    check_not_closed?

    flush
  end

  def refresh
    check_not_closed?

    unless @failed
      data_future = @data_provider.context_data
      if data_future.success?
        assign_data(data_future.data_future)
        log_event(ContextEventLogger::EVENT_TYPE::REFRESH, data_future.data_future)
      else
        set_data_failed(data_future.exception)
        log_error(data_future.exception)
      end
    end
  end

  def close
    unless @closed
      if @pending_count > 0
        flush
      end
      @closed = true
      log_event(ContextEventLogger::EVENT_TYPE::CLOSE, nil)
    end
  end

  def data
    check_ready?(true)

    @data
  end

  private
    def flush
      if !@failed
        if @pending_count > 0
          exposures = nil
          achievements = nil
          event_count = @pending_count

          if event_count > 0
            unless @exposures.empty?
              exposures = @exposures
              @exposures = []
            end

            unless @achievements.empty?
              achievements = @achievements
              @achievements = []
            end

            @pending_count = 0

            event = PublishEvent.new
            event.hashed = true
            event.published_at = @clock.to_i
            event.units = @units.map do |key, value|
              Unit.new(key.to_s, unit_hash(key, value))
            end
            event.exposures = exposures
            event.attributes = @attributes unless @attributes.empty?
            event.goals = achievements unless achievements.nil?
            log_event(ContextEventLogger::EVENT_TYPE::PUBLISH, event)
            @event_handler.publish(self, event)
          end
        end
      else
        @exposures = []
        @achievements = []
        @pending_count = 0
        @data_failed
      end
    end

    def check_not_closed?
      if @closed
        raise IllegalStateException.new("ABSmartly Context is closed")
      end
    end

    def check_ready?(expect_not_closed)
      if !ready?
        raise IllegalStateException.new("ABSmartly Context is not yet ready")
      elsif expect_not_closed
        check_not_closed?
      end
    end

    def experiment_matches(experiment, assignment)
      experiment.id == assignment.id &&
        experiment.unit_type == assignment.unit_type &&
        experiment.iteration == assignment.iteration &&
        experiment.full_on_variant == assignment.full_on_variant &&
        experiment.traffic_split == assignment.traffic_split
    end

    def assignment(experiment_name)
      assignment = @assignment_cache[experiment_name.to_s]

      if !assignment.nil?
        custom = @cassignments.transform_keys(&:to_sym)[experiment_name.to_s.to_sym]
        override = @overrides.transform_keys(&:to_sym)[experiment_name.to_s.to_sym]
        experiment = experiment(experiment_name.to_s)
        if !override.nil?
          if assignment.overridden && assignment.variant == override
            return assignment
          end
        elsif experiment.nil?
          if !assignment.assigned
            return assignment
          end
        elsif custom.nil? || custom == assignment.variant
          return assignment if experiment_matches(experiment.data, assignment)
        end
      end

      custom = @cassignments.transform_keys(&:to_sym)[experiment_name.to_s.to_sym]
      override = @overrides.transform_keys(&:to_sym)[experiment_name.to_s.to_sym]
      experiment = experiment(experiment_name.to_s)

      assignment = Assignment.new
      assignment.name = experiment_name
      assignment.eligible = true

      if !override.nil?
        unless experiment.nil?
          assignment.id = experiment.data.id
          assignment.unit_type = experiment.data.unit_type
        end

        assignment.overridden = true
        assignment.variant = override
      else
        unless experiment.nil?
          unit_type = experiment.data.unit_type

          if !experiment.data.audience.nil? && experiment.data.audience.size > 0
            attrs = @attributes.inject({}) do |hash, attr|
              hash[attr.name] = attr.value
              hash
            end
            match = @audience_matcher.evaluate(experiment.data.audience, attrs)
            if match && !match.result
              assignment.audience_mismatch = true
            end
          end

          if experiment.data.audience_strict && assignment.audience_mismatch
            assignment.variant = 0
          elsif experiment.data.full_on_variant == 0
            uid = @units.transform_keys(&:to_sym)[experiment.data.unit_type.to_sym]
            unless uid.nil?
              assigner = VariantAssigner.new(uid)
              eligible = assigner.assign(experiment.data.traffic_split,
                                         experiment.data.traffic_seed_hi,
                                         experiment.data.traffic_seed_lo) == 1
              if eligible
                if !custom.nil?
                  assignment.variant = custom
                  assignment.custom = true
                else
                  assignment.variant = assigner.assign(experiment.data.split,
                                                       experiment.data.seed_hi,
                                                       experiment.data.seed_lo)
                end
              else
                assignment.eligible = false
                assignment.variant = 0
              end
              assignment.assigned = true
            end
          else
            assignment.assigned = true
            assignment.variant = experiment.data.full_on_variant
            assignment.full_on = true
          end

          assignment.unit_type = unit_type
          assignment.id = experiment.data.id
          assignment.iteration = experiment.data.iteration
          assignment.traffic_split = experiment.data.traffic_split
          assignment.full_on_variant = experiment.data.full_on_variant
        end
      end

      if !experiment.nil? && assignment.variant < experiment.data.variants.length
        assignment.variables = experiment.variables[assignment.variant] || {}
      end

      @assignment_cache[experiment_name.to_s] = assignment
      assignment
    end

    def variable_assignment(key)
      experiment = variable_experiment(key)

      assignment(experiment.data.name) unless experiment.nil?
    end

    def experiment(experiment)
      @index.transform_keys(&:to_sym)[experiment.to_s.to_sym]
    end

    def variable_experiment(key)
      @index_variables.transform_keys(&:to_sym)[key.to_s.to_sym]
    end

    def unit_hash(unit_type, unit_uid)
      @hashed_units[unit_type] = Hashing.hash_unit(unit_uid)
    end

    def variant_assigner(unit_type, unit_hash)
      @assigners[unit_type] ||= VariantAssigner.new(unit_hash)
    end

    def assign_data(data)
      @data = data
      @index = {}
      @index_variables = {}
      if data && !data.experiments.nil? && !data.experiments.empty?
        data.experiments.each do |experiment|
          experiment_variables = ExperimentVariables.new
          experiment_variables.data = experiment
          experiment_variables.variables ||= []
          experiment.variants.each do |variant|
            if !variant.config.nil? && !variant.config.empty?
              variables = @variable_parser.parse(self, experiment.name, variant.name,
                                                 variant.config)
              variables.keys.each { |key| @index_variables[key] = experiment_variables }
              experiment_variables.variables.push(variables)
            else
              experiment_variables.variables.push({})
            end
          end

          @index[experiment.name] = experiment_variables
        end
      end
    end

    def set_data_failed(exception)
      @data_failed = exception
      @index = {}
      @index_variables = {}
      @data = ContextData.new
      @failed = true
    end

    def log_event(event, data)
      unless @event_logger.nil?
        @event_logger.handle_event(event, data)
      end
    end

    def log_error(error)
      unless @event_logger.nil?
        @event_logger.handle_event(ContextEventLogger::EVENT_TYPE::ERROR, error.message)
      end
    end

    attr_accessor :clock,
                  :publish_delay,
                  :event_handler,
                  :event_logger,
                  :data_provider,
                  :variable_parser,
                  :audience_matcher,
                  :units,
                  :failed,
                  :data_lock,
                  :index,
                  :index_variables,
                  :context_lock,
                  :hashed_units,
                  :assigners,
                  :assignment_cache,
                  :event_lock,
                  :exposures,
                  :achievements,
                  :attributes,
                  :overrides,
                  :cassignments,
                  :closed,
                  :refreshing,
                  :ready_future,
                  :refresh_future
    attr_writer :data, :pending_count
end

class Assignment
  attr_accessor :id, :iteration, :full_on_variant, :name, :unit_type,
                :traffic_split, :variant, :assigned, :overridden, :eligible,
                :full_on, :custom, :audience_mismatch, :variables, :exposed

  def initialize
    @variant = 0
    @iteration = 0
    @full_on_variant = 0
    @overridden = false
    @assigned = false
    @exposed = false
    @eligible = true
    @full_on = false
    @custom = false
    @audience_mismatch = false
  end
end

class ExperimentVariables
  attr_accessor :data, :variables
end

class IllegalStateException < StandardError
end
