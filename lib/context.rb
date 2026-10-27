# frozen_string_literal: true

require_relative "hashing"
require_relative "type_utils"
require_relative "variant_assigner"
require_relative "context_event_logger"
require_relative "json/unit"
require_relative "json/attribute"
require_relative "json/exposure"
require_relative "json/publish_event"
require_relative "json/goal_achievement"

class Context
  # Immutable-by-convention snapshot swapped in with a single assignment so
  # readers see either the complete old or the complete new state.
  State = Struct.new(:data, :index, :index_variables, :custom_fields)

  attr_reader :pending_count

  def self.create(clock, config, data_future, data_provider,
                  event_handler, event_logger, variable_parser, audience_matcher)
    Context.new(clock, config, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher)
  end

  def self.create_async(clock, config, data_provider,
                        event_handler, event_logger, variable_parser, audience_matcher)
    context = Context.allocate
    context.send(:initialize_async, clock, config, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
    context
  end

  def initialize(clock, config, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher)
    init_common(clock, config, data_provider, event_handler, event_logger,
                variable_parser, audience_matcher)

    if data_future.success?
      assign_data(data_future.data_future)
      log_event(ContextEventLogger::EVENT_TYPE::READY, data_future.data_future)
    else
      set_data_failed(data_future.exception)
      log_error(data_future.exception)
    end
  end

  def set_data(data_future)
    ready_data = nil
    failure = nil
    @ready_mutex.synchronize do
      if data_future.success?
        assign_data(data_future.data_future)
        ready_data = data_future.data_future
      else
        set_data_failed(data_future.exception)
        failure = data_future.exception
      end
      @ready_condvar.broadcast
    end

    # User callbacks run outside the readiness lock so they may call
    # wait_until_ready.
    if failure.nil?
      log_event(ContextEventLogger::EVENT_TYPE::READY, ready_data)
    else
      log_error(failure)
    end
  end

  def wait_until_ready(timeout = nil)
    @ready_mutex.synchronize do
      unless ready? || failed?
        if timeout
          deadline = Time.now + timeout
          until ready? || failed?
            remaining = deadline - Time.now
            break if remaining <= 0
            @ready_condvar.wait(@ready_mutex, remaining)
          end
        else
          @ready_condvar.wait(@ready_mutex) until ready? || failed?
        end
      end
    end
    self
  end

  def ready?
    !@state.data.nil?
  end

  def failed?
    @failed
  end

  def closed?
    @closed
  end

  def finalized?
    closed?
  end

  def finalizing?
    !@closed && @closing
  end

  def ready_error
    @ready_error
  end

  def get_unit(unit_type)
    @units[unit_type.to_sym]
  end

  def get_units
    @units.dup
  end

  def get_attribute(name)
    result = nil
    @attributes.each do |attr|
      result = attr.value if attr.name == name
    end
    result
  end

  def get_attributes
    result = {}
    @attributes.each do |attr|
      result[attr.name] = attr.value
    end
    result
  end

  def experiments
    check_ready?(false)

    @state.data.experiments.map(&:name)
  end

  def set_override(experiment_name, variant)
    @overrides[experiment_name.to_s.to_sym] = variant
  end

  def set_overrides(overrides)
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

    if uid.is_a?(String)
      trimmed = Hashing.to_utf8(uid).strip
      if trimmed.empty?
        raise IllegalStateException.new("Unit '#{unit_type}' UID must not be blank.")
      end
    elsif TypeUtils.numeric?(uid)
      trimmed = uid
    else
      raise IllegalStateException.new("Unit '#{unit_type}' must be a string or a number.")
    end

    previous = @units[unit_type.to_sym]
    if !previous.nil? && previous != trimmed
      raise IllegalStateException.new("Unit '#{unit_type}' UID already set.")
    end

    @units[unit_type.to_sym] = trimmed
  end

  def set_units(units)
    check_not_closed?

    units.each { |key, value| self.set_unit(key, value) }
  end

  def set_attribute(name, value)
    check_not_closed?

    @attributes.push(Attribute.new(name, value, @clock.to_i))
    @attrs_seq += 1
  end

  def set_attributes(attributes)
    check_not_closed?

    attributes.each { |key, value| self.set_attribute(key, value) }
  end

  def treatment(experiment_name)
    check_ready?(true)

    assignment = assignment(experiment_name)
    queue_exposure(assignment)
    assignment.variant
  end

  def queue_exposure(assignment)
    exposure = nil
    @queue_mutex.synchronize do
      # Checked under the queue lock so an exposure cannot slip in after close
      # sealed the queue and be stranded.
      check_not_closed?

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
      end
    end
    # User callbacks run outside the lock so they can call publish/track.
    log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposure) unless exposure.nil?
  end

  def peek_treatment(experiment_name)
    check_ready?(true)

    assignment(experiment_name).variant
  end

  alias peek peek_treatment

  def variable_keys
    check_ready?(true)

    hsh = {}
    @state.index_variables.each do |key, values|
      hsh[key] = values.map { |v| v.data.name }
    end
    hsh
  end

  def variable_value(key, default_value)
    check_ready?(true)

    assignment = variable_assignment(key)
    unless assignment.nil? || assignment.variables.nil?
      queue_exposure(assignment)
      return assignment.variables[key.to_s.to_sym] if assignment.variables.key?(key.to_s.to_sym)
    end

    default_value
  end

  def custom_field_keys
    check_ready?(true)

    keys = []

    @state.data.experiments.each do |experiment|
      custom_field_values = experiment.custom_field_values
      if custom_field_values != nil
        custom_field_values.each do |custom_field|
          keys.append(custom_field.name)
        end
      end
    end

    return keys.sort.uniq
  end

  def custom_field_value(experimentName, key)
    custom_field(experimentName, key)&.value
  end

  def custom_field_value_type(experimentName, key)
    custom_field(experimentName, key)&.type
  end

  def custom_field_type(experimentName, key)
    custom_field_value_type(experimentName, key)
  end

  def peek_variable_value(key, default_value)
    check_ready?(true)

    assignment = variable_assignment(key)
    return assignment.variables[key.to_s.to_sym] if !assignment.nil? &&
      !assignment.variables.nil? &&
      assignment.variables.key?(key.to_s.to_sym)

    default_value
  end

  def track(goal_name, properties = nil)
    check_not_closed?
    unless properties.nil? || TypeUtils.object?(properties)
      raise ArgumentError, "Goal '#{goal_name}' properties must be of type object."
    end

    achievement = GoalAchievement.new
    achievement.achieved_at = @clock.to_i
    achievement.name = goal_name
    achievement.properties = properties.nil? ? nil : properties.dup

    @queue_mutex.synchronize do
      check_not_closed?

      @pending_count += 1
      @achievements.push(achievement)
    end
    log_event(ContextEventLogger::EVENT_TYPE::GOAL, achievement)
  end

  def publish
    check_ready?(true)

    result = flush
    result
  end

  # A failed context is never recovered: refresh is a no-op. A failed fetch
  # keeps the current data, logs the error and returns it.
  def refresh
    check_ready?(true)
    return nil if @failed

    data_future = @data_provider.context_data
    if data_future.success?
      assign_data(data_future.data_future)
      log_event(ContextEventLogger::EVENT_TYPE::REFRESH, data_future.data_future)
      nil
    else
      log_error(data_future.exception)
      data_future.exception
    end
  end

  # Publishes pending events, then seals the context. If the final publish
  # fails the context stays open with the events queued, so close can be
  # retried; the failure is returned (or raised, if the publisher raised).
  def close
    return nil if @closed

    # Called from a logger callback while a publish is in flight: defer so the
    # events queued by the callback are still sent before finalizing.
    if @publish_mutex.owned?
      @close_pending = true
      return nil
    end

    @closing = true
    begin
      loop do
        result = flush
        # A failed context discards its events; only a real publish failure
        # keeps the context open.
        return result if !@failed && publish_failed?(result)

        sealed = @queue_mutex.synchronize do
          next :done if @closed
          # Events queued while the final publish was in flight go out too.
          next :retry unless @exposures.empty? && @achievements.empty?

          @closed = true
          :sealed
        end
        return nil if sealed == :done
        next if sealed == :retry

        log_event(ContextEventLogger::EVENT_TYPE::FINALIZE, nil)
        return nil
      end
    ensure
      @closing = false
    end
  end

  def finalize
    close
  end

  def data
    check_ready?(true)

    @state.data
  end

  def inspect
    "#<Context ready=#{ready?} closed=#{closed?}>"
  end

  private
    def flush
      if @failed
        @queue_mutex.synchronize do
          @exposures = []
          @achievements = []
          @pending_count = 0
        end
        return @data_failed
      end

      # Serialize publishes so a queued event is part of at most one in-flight
      # request; on failure the events stay queued for the next attempt.
      # A logger callback that calls publish from inside a publish must not
      # deadlock or re-send the in-flight snapshot; the outer call owns it.
      return nil if @publish_mutex.owned?

      result = @publish_mutex.synchronize do
        exposures = achievements = nil
        event_count = 0
        @queue_mutex.synchronize do
          exposures = @exposures.dup
          achievements = @achievements.dup
          event_count = exposures.size + achievements.size
        end

        next nil unless event_count > 0

        event = PublishEvent.new
        event.hashed = true
        event.published_at = @clock.to_i
        event.units = @units.map do |key, value|
          Unit.new(key.to_s, unit_hash(key, value))
        end
        event.exposures = exposures unless exposures.empty?
        event.attributes = @attributes unless @attributes.empty?
        event.goals = achievements unless achievements.empty?
        # Like the JavaScript SDK, the publish event is logged once the batch is
        # delivered; a failed delivery logs an error event instead.
        begin
          response = @event_handler.publish(self, event)
        rescue StandardError => e
          log_error(e)
          raise
        end

        if response.is_a?(Exception)
          warn("Publish failed: #{response.message}")
          log_error(response)
          response
        elsif response.respond_to?(:exception) && response.exception
          log_error(response.exception)
          response
        elsif response.respond_to?(:success?) && !response.success?
          warn("Publish failed (status=#{response.respond_to?(:status) ? response.status : 'unknown'})")
          log_error(StandardError.new("Publish failed (status=#{response.respond_to?(:status) ? response.status : 'unknown'})"))
          response
        else
          log_event(ContextEventLogger::EVENT_TYPE::PUBLISH, event)
          # Remove only the events that were published; others may have been
          # queued concurrently while the request was in flight.
          @queue_mutex.synchronize do
            @exposures.shift(exposures.size)
            @achievements.shift(achievements.size)
            @pending_count = [@pending_count - event_count, 0].max
          end
          response
        end
      end

      if @close_pending
        @close_pending = false
        close unless @closed
      end
      result
    end

    def publish_failed?(result)
      result.is_a?(Exception) ||
        (result.respond_to?(:exception) && result.exception) ||
        (result.respond_to?(:success?) && !result.success?)
    end

    def check_not_closed?
      if @closed
        raise IllegalStateException.new("ABsmartly Context is finalized.")
      end
    end

    def check_ready?(expect_not_closed)
      if !ready?
        raise IllegalStateException.new("ABsmartly Context is not yet ready.")
      elsif expect_not_closed
        check_not_closed?
      end
    end

    def custom_field(experiment_name, key)
      check_ready?(true)
      @state.custom_fields.dig(experiment_name, key)
    end

    def experiment_matches(experiment, assignment)
      experiment.id == assignment.id &&
        experiment.unit_type == assignment.unit_type &&
        experiment.iteration == assignment.iteration &&
        experiment.full_on_variant == assignment.full_on_variant &&
        experiment.traffic_split == assignment.traffic_split
    end

    def audience_matches(experiment, assignment)
      if !experiment.audience.nil? && experiment.audience.size > 0
        if @attrs_seq > (assignment.attrs_seq || 0)
          attrs = @attributes.inject({}) do |hash, attr|
            hash[attr.name] = attr.value
            hash
          end
          match = @audience_matcher.evaluate(experiment.audience, attrs)
          # An indeterminate result (no filter, bad JSON) keeps the cached flag.
          new_audience_mismatch = match.nil? ? assignment.audience_mismatch : !match.result

          if new_audience_mismatch != assignment.audience_mismatch
            return false
          end

          assignment.attrs_seq = @attrs_seq
        end
      end
      true
    end

    def assignment(experiment_name, state = @state)
      assignment = @assignment_cache[experiment_name.to_s]
      exp_key = experiment_name.to_s.to_sym

      if !assignment.nil?
        custom = @cassignments[exp_key]
        override = @overrides[exp_key]
        experiment = experiment(experiment_name.to_s, state)
        if !override.nil?
          if assignment.overridden && assignment.variant == override
            return assignment
          end
        elsif experiment.nil?
          if !assignment.assigned
            return assignment
          end
        elsif custom.nil? || custom == assignment.variant
          if experiment_matches(experiment.data, assignment) && audience_matches(experiment.data, assignment)
            return assignment
          end
        end
      end

      custom = @cassignments[exp_key]
      override = @overrides[exp_key]
      experiment = experiment(experiment_name.to_s, state)

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
            uid = @units[experiment.data.unit_type.to_sym]
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
          assignment.attrs_seq = @attrs_seq
        end
      end

      if !experiment.nil? && assignment.variant >= 0 && assignment.variant < experiment.data.variants.length
        assignment.variables = experiment.variables[assignment.variant] || {}
      end

      @assignment_cache[experiment_name.to_s] = assignment
      assignment
    end

    def variable_assignment(key)
      state = @state
      experiment = variable_experiment(key, state)

      assignment(experiment.data.name, state) unless experiment.nil?
    end

    def experiment(experiment, state = @state)
      state.index[experiment.to_s.to_sym]
    end

    def variable_experiment(key, state = @state)
      experiments = state.index_variables[key.to_s.to_sym]
      experiments&.first
    end

    def unit_hash(unit_type, unit_uid)
      @hashed_units[unit_type] = Hashing.hash_unit(unit_uid)
    end

    def variant_assigner(unit_type, unit_hash)
      @assigners[unit_type] ||= VariantAssigner.new(unit_hash)
    end

    def assign_data(data)
      index = {}
      index_variables = {}
      custom_fields = {}

      if data && !data.experiments.nil? && !data.experiments.empty?
        data.experiments.each do |experiment|
          experiment_custom_field_values = {}

          experiment_variables = ExperimentVariables.new
          experiment_variables.data = experiment
          experiment_variables.variables ||= []
          experiment.variants.each do |variant|
            if !variant.config.nil? && !variant.config.empty?
              variables = @variable_parser.parse(self, experiment.name, variant.name,
                                                 variant.config)
              variables.keys.each do |key|
                index_variables[key] ||= []
                index_variables[key] << experiment_variables unless index_variables[key].include?(experiment_variables)
              end
              experiment_variables.variables.push(variables)
            else
              experiment_variables.variables.push({})
            end
          end

          if !experiment.custom_field_values.nil?
            experiment.custom_field_values.each do |custom_field_value|
              value = ContextCustomFieldValues.new
              value.type = custom_field_value.type

              if !custom_field_value.value.nil?
                custom_value = custom_field_value.value

                if custom_field_value.type.start_with?("json")
                  value.value = @variable_parser.parse(self, experiment.name, custom_field_value.name, custom_value)

                elsif custom_field_value.type.start_with?("boolean")
                  value.value = custom_value == "true"

                elsif custom_field_value.type.start_with?("number")
                  value.value = custom_value.to_i

                else
                  value.value = custom_field_value.value
                end

                experiment_custom_field_values[custom_field_value.name] = value

              end

            end
          end

          index[experiment.name.to_sym] = experiment_variables
          custom_fields[experiment.name] = experiment_custom_field_values
        end
      end

      # Publish the fully built snapshot; the maps are never mutated after this.
      @state = State.new(data, index, index_variables, custom_fields)
    end

    def set_data_failed(exception)
      @data_failed = exception
      @ready_error = exception
      @state = State.new(ContextData.new, {}, {}, {})
      @failed = true
    end

    # A raising logger must not break the operation that is logging.
    def log_event(event, data)
      unless @event_logger.nil?
        @event_logger.handle_event(event, data)
      end
    rescue StandardError => e
      warn("Context event logger raised: #{e.class} - #{e.message}")
    end

    def log_error(error)
      unless @event_logger.nil?
        @event_logger.handle_event(ContextEventLogger::EVENT_TYPE::ERROR, error.message)
      end
    rescue StandardError => e
      warn("Context event logger raised: #{e.class} - #{e.message}")
    end

    def init_common(clock, config, data_provider, event_handler, event_logger,
                    variable_parser, audience_matcher)
      @state = State.new(nil, {}, {}, {})
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
      @closing = false
      @failed = false
      @ready_error = nil

      @units = {}
      @attributes = []
      @overrides = {}
      @cassignments = {}
      @assigners = {}
      @hashed_units = {}
      @pending_count = 0
      @exposures ||= []
      @attrs_seq = 0
      @ready_mutex = Mutex.new
      @ready_condvar = ConditionVariable.new
      @queue_mutex = Mutex.new
      @publish_mutex = Mutex.new
      @close_pending = false

      set_units(config.units) if config.units
      set_attributes(config.attributes) if config.attributes
      set_overrides(config.overrides) if config.overrides
      set_custom_assignments(config.custom_assignments) if config.custom_assignments
    end

    def initialize_async(clock, config, data_provider, event_handler, event_logger,
                         variable_parser, audience_matcher)
      init_common(clock, config, data_provider, event_handler, event_logger,
                  variable_parser, audience_matcher)
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
                :full_on, :custom, :audience_mismatch, :variables, :exposed, :attrs_seq

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
    @attrs_seq = 0
  end
end

class ExperimentVariables
  attr_accessor :data, :variables
end

class ContextCustomFieldValues
  attr_accessor :type, :value
end

class IllegalStateException < StandardError
end
