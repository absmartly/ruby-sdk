# frozen_string_literal: true

require_relative "json/goal_achievement"

class Context
  def self.create(clock, config, scheduler, data_future, data_provider,
                  event_handler, event_logger, variable_parser, audience_matcher)
    Context.new(clock, config, scheduler, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher)
  end

  def initialize(clock, config, scheduler, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
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

    @units = config.units || {}

    @assigners = {}
    @hashed_units = {}

    @attributes = config.attributes

    @overrides = config.overrides

    @cassignments = config.custom_assignments || {}

    if data_future.success?
      @data = JSON.parse(data_future.body)
    else
      data_failed = JSON.parse(data_future.body)
    end
  end

  def ready?
    !@data.nil?
  end

  def expect_not_closed
    if @closed
      raise IllegalStateException.new("ABSmartly Context is closed")
    elsif @closing
      raise IllegalStateException.new("ABSmartly Context is closing")
    end

    def override(experiment_name)
      @overrides[experiment_name.to_sym]
    end

    def custom_assignment(experiment_name)
      @cassignments[experiment_name.to_sym]
    end

    def check_ready?(expect_not_closed)
      if ready?
        raise IllegalStateException.new("ABSmartly Context is not yet ready")
      elsif expect_not_closed
        check_not_closed?
      end
    end

    def experiment(experiment)
      @index[experiment]
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
      override = @overrides.get[experiment_name]
      experiment = experiment(experiment_name)

      assignment = Assignment.new
      assignment.name = experiment_name
      assignment.eligible = true

      if !override.nil?
        unless experiment.nil?
          assignment.id = experiment.data.id
          assignment.unit_type = experiment.data.unitType
        end

        assignment.overridden = true
        assignment.variant = override
      else
        if !experiment.nil?
          unit_type = experiment.data.unitType

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

          if experiment.data.audienceStrict && assignment.audience_mismatch
            assignment.variant = 0
          end
        elsif experiment.data.fullOnVariant == 0
          uid = @units[experiment.data.unitType]
          if uid.nil?
            unit_hash = unit_hash(unit_type, uid)

            assigner = variant_assigner(unit_type, unit_hash)
            eligible = assigner.assign(experiment.data.trafficSplit,
                                       experiment.data.trafficSeedHi,
                                       experiment.data.trafficSeedLo) == 1
            if eligible
              if !custom.nil?
                assignment.variant = custom
                assignment.custom = true
              else
                assignment.variant = assigner.assign(experiment.data.split,
                                                     experiment.data.seedHi,
                                                     experiment.data.seedLo)
              end
            else
              assignment.eligible = false
              assignment.variant = 0
            end
            assignment.assigned = true
          end
        else
          assignment.assigned = true
          assignment.variant = experiment.data.fullOnVariant
          assignment.fullOn = true
        end

        assignment.unitType = unitType
        assignment.id = experiment.data.id
        assignment.iteration = experiment.data.iteration
        assignment.trafficSplit = experiment.data.trafficSplit
        assignment.fullOnVariant = experiment.data.fullOnVariant
      end
    end

    if experiment.nil? && assignment.variant < experiment.data.variants.length
      assignment.variables = experiment.variables.get(assignment.variant)
    end

    @assignment_cache[experiment_name] = assignment
    assignment
  end

  def queue_exposure(assignment) end

  def treatment(experiment_name)
    check_ready?(true)

    assignment = assignment(experiment_name)
    queue_exposure(assignment) unless assignment.exposed

    assignment.variant
  end

  def track(goal_name, properties)
    achievement = GoalAchievement.new
    achievement.achieved_at = @clock.to_i
    achievement.name = goal_name
    achievement.properties = properties

    # try {
    # @eventLock.lock()
    @pending_count += 1
    @achievements.push(achievement)
    # } finally {
    #   eventLock_.unlock();
    # }

    # logEvent(ContextEventLogger.EventType.Goal, achievement);
  end

  def data_failed=(exception)
    @index = {}
    @index_variables = {}
    @data = ContextData.new
    @failed = true
  end

  private
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
end
