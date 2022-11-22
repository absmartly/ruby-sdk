# frozen_string_literal: true

require_relative "hashing"
require_relative "variant_assigner"
require_relative "json/attribute"
require_relative "json/exposure"
require_relative "json/goal_achievement"

class Context
  def self.create(clock, config, scheduler, data_future, data_provider,
                  event_handler, event_logger, variable_parser, audience_matcher)
    Context.new(clock, config, scheduler, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher)
  end

  def initialize(clock, config, scheduler, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
    @index = []
    @achievements = []
    @assignment_cache = {}
    @assignments = {}
    @clock = clock
    @publish_delay = config.publish_delay
    @refresh_interval = config.refresh_interval
    @event_handler = event_handler
    @event_logger = !config.event_logger.nil? ? config.event_logger : event_logger
    @data_provider = data_provider
    @variable_parser = variable_parser
    @audience_matcher = audience_matcher
    @scheduler = scheduler
    @closed = false
    @closing = false

    @units = config.units || {}

    @assigners = {}
    @hashed_units = {}

    @attributes = config.attributes || {}

    @overrides = config.overrides || {}

    @cassignments = config.custom_assignments || {}

    if data_future.success?
      assign_data(data_future.data_future)
    else
      @data_failed = data_future.exception
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

  def override=(experiment_name, variant)
    @overrides[experiment_name] = variant
  end

  def overrides=(overrides)
    @overrides.merge!(overrides)
  end

  def override(experiment_name)
    @overrides[experiment_name]
  end

  def custom_assignment=(experiment_name, variant)
    check_not_closed?

    @cassignments[experiment_name] = variant
  end

  def custom_assignments=(custom_assignments)
    @cassignments.merge!(custom_assignments)
  end

  def custom_assignment(experiment_name)
    @cassignments[experiment_name]
  end

  def unit=(unit_type, uid)
    check_not_closed?

    previous = @units[unit_type]
    if !previous.nil? && !previous == uid
      raise ArgumentError.new("Unit '#{unit_type}' already set.")
    end

    trimmed = uid.strip
    if trimmed.empty?
      raise ArgumentError.new("Unit '#{unit_type}' UID must not be blank.")
    end

    @units[unit_type] = trimmed
  end

  def units=(units)
    units.each { |key, value| self.unit = key, value }
  end

  def attribute=(name, value)
    @attributes.push(Attribute.new(name, value, @clock.to_i))
  end

  def attributes=(attributes)
    attributes.each { |key, value| self.attribute = key, value }
  end

  def treatment(experiment_name)
    check_ready?(true)
    assignment = assignment(experiment_name)
    unless assignment.exposed
      assignment.exposed = true

      queue_exposure(assignment)
    end

    assignment.variant
  end

  def queue_exposure(assignment)
    unless assignment.exposed
      exposure = Exposure.new
      exposure.id = assignment.id
      exposure.name = assignment.name
      exposure.unit = assignment.unit_type
      exposure.variant = assignment.variant
      exposure.exposed_at = @clock
      exposure.assigned = assignment.assigned
      exposure.eligible = assignment.eligible
      exposure.overridden = assignment.overridden
      exposure.full_on = assignment.full_on
      exposure.custom = assignment.custom
      exposure.audience_mismatch = assignment.audience_mismatch

      @pending_count += 1
      @exposures.push(exposure)
    end
  end

  def peek_treatment(experiment_name)
    check_ready?(true)

    assignment(experiment_name).variant
  end

  def variable_keys
    check_ready?(true)

    @index_variables.map { |key, value| Hash[key, value.data.name] }
  end

  def variable_value(key, default_value)
    assignment = variable_assignment(key)
    unless assignment.nil? && assignment.variables.nil?
      queue_exposure(assignment) unless assignment.exposed
      return assignment.variables[key] if assignment.variables.key?(key)
    end

    default_value
  end

  def peek_variable_value(key, default_value)
    check_ready?(true)

    assignment = variable_assignment(key)
    return assignment.variables.get(key) unless assignment.nil? &&
      assignment.variables.nil? &&
      assignment.variables.key?(key)

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

    set_timeout
  end

  def publish_async
    check_not_closed?

    flush
  end

  def publish
    publish_async
  end

  def refresh_async
    @data_provider.context_data unless @failed
  end

  def refresh
    refresh_async
  end

  def close_async
    unless @closed && @closing
      @closing = true
      clear_refresh_timer

      if @pending_count > 0
        flush
      end
      @closed = true
      @closing = false
      @closing_future = nil
    end
  end

  def close
    close_async
  end

  private
    def flush
      clear_timeout
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
          end

          if event_count > 0
            event = PublishEvent.new
            event.hashed = true
            event.published_at = @clock.to_i
            event.units = @units.to_a
            event.attributes = @attributes.empty? ? nil : @attributes.to_a
            event.exposures = exposures
            event.goals = achievements

            @event_handler.publish(self, event)
          end
        end
      else
        @exposures = []
        @achievements = []
        @pending_count = 0
      end
    end

    def check_not_closed?
      if @closed
        raise IllegalStateException.new("ABSmartly Context is closed")
      elsif @closing
        raise IllegalStateException.new("ABSmartly Context is closing")
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
      assignment = @assignment_cache[experiment_name]

      if !assignment.nil?
        custom = @cassignments[experiment_name]
        override = @overrides[experiment_name]
        experiment = experiment(experiment_name)
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

      custom = @cassignments[experiment_name]
      override = @overrides[experiment_name]
      experiment = experiment(experiment_name)

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
            if match.nil?
              assignment.audience_mismatch = !match
            end
          end

          if experiment.data.audience_strict && assignment.audience_mismatch
            assignment.variant = 0
          elsif experiment.data.full_on_variant == 0
            uid = @units[experiment.data.unit_type]
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

      @assignment_cache[experiment_name] = assignment
      assignment
    end

    def variable_assignment(key)
      experiment = variable_experiment(key)


      assignment(experiment.data.name) unless experiment.nil?
    end

    def experiment(experiment)
      @index[experiment]
    end

    def variable_experiment(key)
      @index_variables[key]
    end

    def unit_hash(unit_type, unit_uid)
      @hashed_units[unit_type] = Hashing.hash_unit(unit_uid)
    end

    def variant_assigner(unit_type, unit_hash)
      @assigners[unit_type] ||= VariantAssigner.new(unit_hash)
    end

    def set_timeout
      if ready? && @timeout.nil?
        flush
      end
    end

    def clear_timeout
      unless @timeout.nil?
        @timeout = nil
      end
    end

    def refresh_timer
      if @refresh_interval > 0 && @refresh_timer.nil?
        @refresh_timer = Time.now.to_i
        refresh_async
      end
    end

    def clear_refresh_timer
      @refresh_timer = nil
    end

    def assign_data(data)
      @data = data
      @index = {}
      @index_variables = {}
      data.experiments.each do |experiment|
        experiment_variables = ExperimentVariables.new
        experiment_variables.data = experiment
        experiment_variables.variables = experiment.variants.size
        experiment.variants.each do |variant|
          if !variant.config.nil? && !variant.config.empty?
            variables = @variable_parser.parse(self, experiment.name, variant.name,
                                               variant.config)
            variables.keys.each { |key| @index_variables[key] = experiment_variables }

            experiment_variables.variables.push(variables)
          else
            experiment_variables.variables = {}
          end
        end

        @index[experiment.name] = experiment_variables

        refresh_timer
      end
    end

    def data_failed=(exception)
      @index = {}
      @index_variables = {}
      @data = ContextData.new
      @failed = true
    end

    attr_accessor :clock,
                  :publish_delay,
                  :event_handler,
                  :event_logger,
                  :data_provider,
                  :variable_parser,
                  :audience_matcher,
                  :scheduler,
                  :units,
                  :failed,
                  :data_lock,
                  :data,
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
                  :pending_count,
                  :closing,
                  :closed,
                  :refreshing,
                  :ready_future,
                  :closing_future,
                  :refresh_future,
                  :timeout_lock,
                  :timeout,
                  :refresh_timer
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
