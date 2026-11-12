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
                  event_handler, event_logger, variable_parser, audience_matcher,
                  application: nil, environment: nil)
    Context.new(clock, config, data_future, data_provider,
                event_handler, event_logger, variable_parser, audience_matcher,
                application: application, environment: environment)
  end

  def self.create_async(clock, config, data_provider,
                        event_handler, event_logger, variable_parser, audience_matcher,
                        application: nil, environment: nil)
    context = Context.allocate
    context.send(:initialize_async, clock, config, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher,
                 application: application, environment: environment)
    context
  end

  def initialize(clock, config, data_future, data_provider,
                 event_handler, event_logger, variable_parser, audience_matcher,
                 application: nil, environment: nil)
    init_common(clock, config, data_provider, event_handler, event_logger,
                variable_parser, audience_matcher, application, environment)

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

  attr_reader :ready_error

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

    if uid.nil?
      raise IllegalStateException.new("Unit '#{unit_type}' UID must not be blank.")
    elsif Absmartly::TypeUtils.numeric?(uid)
      trimmed = uid
    else
      # Like v1.3.0, any other value (Symbol, session id, UUID object) is
      # stored as its to_s text.
      uid = uid.respond_to?(:to_str) ? uid.to_str : uid.to_s
      trimmed = Hashing.to_utf8(uid).strip
      if trimmed.empty?
        raise IllegalStateException.new("Unit '#{unit_type}' UID must not be blank.")
      end
    end

    previous = @units[unit_type.to_sym]
    if !previous.nil? && previous != trimmed
      raise IllegalStateException.new("Unit '#{unit_type}' already set.")
    end

    @units[unit_type.to_sym] = trimmed
    invalidate_assignments_missing_unit(unit_type.to_s)
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
        exposure.rule_override = assignment.rule_override

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

  # Maps each variable key to the name of the experiment whose value
  # variable_value returns for it, as in v1.3.0.
  def variable_keys
    check_ready?(true)

    hsh = {}
    @state.index_variables.each { |key, values| hsh[key] = values.first.data.name }
    hsh
  end

  # Maps each variable key to the names of every experiment that defines it.
  def variable_keys_list
    check_ready?(true)

    hsh = {}
    @state.index_variables.each do |key, values|
      hsh[key] = values.map { |v| v.data.name }
    end
    hsh
  end

  def variable_value(key, default_value)
    check_ready?(true)

    resolve_variable_value(key, default_value, true)
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

    keys.sort.uniq
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

    resolve_variable_value(key, default_value, false)
  end

  def track(goal_name, properties = nil)
    check_not_closed?
    # Hash-like objects such as ActionController::Parameters are accepted
    # through to_unsafe_h or to_h, as v1.3.0 accepted any properties object.
    # to_unsafe_h comes first because Parameters#to_h raises unless permitted.
    if !properties.nil? && !Absmartly::TypeUtils.object?(properties) && !properties.is_a?(Array)
      if properties.respond_to?(:to_unsafe_h)
        properties = properties.to_unsafe_h
      elsif properties.respond_to?(:to_h)
        properties = properties.to_h
      end
    end
    unless properties.nil? || Absmartly::TypeUtils.object?(properties)
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

    flush
  end

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
  # fails the context stays open with the events queued and the failure is
  # raised, so close can be retried. Logs the "close" event only once the
  # context is sealed; finalize does the same but logs "finalize".
  def close
    seal(ContextEventLogger::EVENT_TYPE::CLOSE)
  end

  def finalize
    seal(ContextEventLogger::EVENT_TYPE::FINALIZE)
  end

  def data
    check_ready?(true)

    @state.data
  end

  def inspect
    "#<Context ready=#{ready?} closed=#{closed?}>"
  end

  private
    def seal(event_type)
      return nil if @closed

      # Called from a logger callback while a publish is in flight: defer so the
      # events queued by the callback are still sent before finalizing.
      if @publish_mutex.owned?
        @close_pending = event_type
        return nil
      end

      @closing = true
      begin
        loop do
          result = flush
          raise_publish_failure(result) if !@failed && publish_failed?(result)

          sealed = @queue_mutex.synchronize do
            next :done if @closed
            next :retry unless @exposures.empty? && @achievements.empty?

            @closed = true
            :sealed
          end
          return nil if sealed == :done
          next if sealed == :retry

          log_event(event_type, nil)
          return nil
        end
      ensure
        @closing = false
      end
    end

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
          log_error(response)
          response
        elsif response.respond_to?(:exception) && response.exception
          log_error(response.exception)
          response
        elsif response.respond_to?(:success?) && !response.success?
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
        event_type = @close_pending
        @close_pending = false
        seal(event_type) unless @closed || publish_failed?(result)
      end
      result
    end

    def publish_failed?(result)
      result.is_a?(Exception) ||
        (result.respond_to?(:exception) && result.exception) ||
        (result.respond_to?(:success?) && !result.success?)
    end

    def raise_publish_failure(result)
      if result.is_a?(Exception)
        raise result
      elsif result.respond_to?(:exception) && result.exception
        raise result.exception
      else
        status = result.respond_to?(:status) ? result.status : "unknown"
        raise StandardError.new("Publish failed (status=#{status})")
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

    # System values go in first, then user-set attributes overlay them, so a
    # user attribute always wins over the system value for the same name, even
    # when set after the context was created (the @attrs_seq bump re-evaluates
    # the cached assignment). Empty system values were skipped at init, so a
    # missing config leaves the key out rather than matching on "".
    def attributes_map
      attrs = @system_attributes.dup
      @attributes.each { |attr| attrs[attr.name.to_s] = attr.value }
      attrs
    end

    # A split rule resolved while its unit was missing gave the no-unit
    # variant; once the unit is set, unexposed ones are rebuilt. Exposed ones
    # stay, so the user never switches variant or gets a second exposure.
    def invalidate_assignments_missing_unit(unit_type)
      @assignment_mutex.synchronize do
        @assignment_cache.delete_if do |_name, assignment|
          assignment.unit_type.to_s == unit_type && !assignment.exposed && assignment.rule_missing_unit
        end
      end
    end

    def rule_key(experiment)
      rules = experiment.assignment_rules
      rules.is_a?(String) && !rules.empty? ? "#{rules}:#{@environment}" : ""
    end

    # Re-resolves the rules and audience when the rules, the environment or an
    # attribute changed since the assignment was built.
    def audience_matches(entry, assignment)
      experiment = entry.data
      key = rule_key(experiment)
      key_changed = key != (assignment.rule_key || "")

      return false if key_changed && key.empty? && assignment.rule_override

      if @attrs_seq > (assignment.attrs_seq || 0) || key_changed
        attrs = attributes_map

        unless key.empty?
          pinned_missing = assignment.exposed && assignment.rule_missing_unit
          rule = resolve_rule(entry, attrs, pinned_missing)
          return false if rule&.first != assignment.rule_variant

          assignment.rule_missing_unit = rule ? rule.last : false
        end

        if !assignment.rule_override && !experiment.audience.nil? && experiment.audience.size > 0
          match = @audience_matcher.evaluate(experiment.audience, attrs)
          # An indeterminate result (no filter, bad JSON) keeps the cached flag.
          new_audience_mismatch = match.nil? ? assignment.audience_mismatch : !match.result

          return false if new_audience_mismatch != assignment.audience_mismatch
        end

        assignment.rule_key = key
        assignment.attrs_seq = @attrs_seq
      end
      true
    end

    # Returns [variant, missing_unit] for the first matching assignment rule,
    # or nil when no rule applies. An assign variant out of range or a split
    # without one percentage per variant falls back to normal assignment. A
    # split is hashed with the experiment's own seed; without the unit it
    # gives the experiment's no-unit variant (the full-on variant, else 0).
    def resolve_rule(entry, attrs, unit_pinned_missing)
      experiment = entry.data
      return nil if entry.rules.nil?

      action = @audience_matcher.evaluate_parsed_rules(entry.rules, @environment, attrs)
      return nil if action.nil?

      variant_count = experiment.variants.length
      unless action.split?
        return action.variant >= 0 && action.variant < variant_count ? [action.variant, false] : nil
      end
      return nil if action.split.length != variant_count

      unit_type = experiment.unit_type
      uid = unit_type.nil? || unit_pinned_missing ? nil : @units[unit_type.to_sym]
      return [experiment.full_on_variant, true] if uid.nil?

      assigner = variant_assigner(unit_type, uid)
      [assigner.assign(action.split, experiment.seed_hi, experiment.seed_lo), false]
    end

    def assignment(experiment_name, state = @state)
      @assignment_mutex.synchronize { cached_or_new_assignment(experiment_name, state) }
    end

    def cached_or_new_assignment(experiment_name, state)
      assignment = @assignment_cache[experiment_name.to_s]
      exp_key = experiment_name.to_s.to_sym
      custom = @cassignments[exp_key]
      override = @overrides[exp_key]
      experiment = experiment(experiment_name.to_s, state)

      if !assignment.nil?
        if !override.nil?
          return assignment if assignment.overridden && assignment.variant == override
        elsif experiment.nil?
          # A rule-won assignment came from the experiment's rules, so it is
          # rebuilt once the experiment is gone.
          return assignment if !assignment.assigned && !assignment.rule_override
        elsif (assignment.rule_override || custom.nil? || custom == assignment.variant) &&
              experiment_matches(experiment.data, assignment) && audience_matches(experiment, assignment)
          # A matching rule wins over a custom assignment, so a custom
          # mismatch is not staleness.
          return assignment
        end
      end

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
      elsif !experiment.nil?
        data = experiment.data
        assignment.unit_type = data.unit_type
        assignment.id = data.id
        assignment.iteration = data.iteration
        assignment.traffic_split = data.traffic_split
        assignment.full_on_variant = data.full_on_variant
        assignment.rule_key = rule_key(data)
        rule = assignment.rule_key.empty? ? nil : resolve_rule(experiment, attributes_map, false)
        assignment.rule_variant = rule&.first
        assignment.rule_missing_unit = rule ? rule.last : false

        # A matching rule is an explicit assignment like an override: it wins
        # over the audience, traffic, full-on and custom assignments, and the
        # exposure is flagged so the backend can exclude it from analysis.
        if rule
          assignment.rule_override = true
          assignment.variant = rule.first
        else
          if !data.audience.nil? && data.audience.size > 0
            match = @audience_matcher.evaluate(data.audience, attributes_map)
            assignment.audience_mismatch = true if match && !match.result
          end

          if data.audience_strict && assignment.audience_mismatch
            assignment.variant = 0
          elsif data.full_on_variant == 0
            uid = @units[data.unit_type.to_sym]
            unless uid.nil?
              assigner = VariantAssigner.new(uid)
              eligible = assigner.assign(data.traffic_split, data.traffic_seed_hi, data.traffic_seed_lo) == 1
              if eligible
                if !custom.nil?
                  assignment.variant = custom
                  assignment.custom = true
                else
                  assignment.variant = assigner.assign(data.split, data.seed_hi, data.seed_lo)
                end
              else
                assignment.eligible = false
                assignment.variant = 0
              end
              assignment.assigned = true
            end
          else
            assignment.assigned = true
            assignment.variant = data.full_on_variant
            assignment.full_on = true
          end
        end
        assignment.attrs_seq = @attrs_seq
      end

      if !experiment.nil? && assignment.variant >= 0 && assignment.variant < experiment.data.variants.length
        assignment.variables = experiment.variables[assignment.variant] || {}
      end

      @assignment_cache[experiment_name.to_s] = assignment
      assignment
    end

    # Like the JavaScript SDK, a key shared by several experiments reads from
    # the first one, in experiment id order, that the unit is assigned to or
    # overridden in; each experiment visited on the way is exposed.
    def resolve_variable_value(key, default_value, expose)
      state = @state
      key = key.to_s.to_sym
      (state.index_variables[key] || []).each do |experiment|
        assignment = assignment(experiment.data.name, state)
        next if assignment.variables.nil?

        queue_exposure(assignment) if expose
        if assignment.variables.key?(key) && (assignment.assigned || assignment.overridden || assignment.rule_override)
          return assignment.variables[key]
        end
      end

      default_value
    end

    def experiment(experiment, state = @state)
      state.index[experiment.to_s.to_sym]
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
          experiment_variables.rules = @audience_matcher.parse_rules(experiment.assignment_rules)
          experiment_variables.variables ||= []
          experiment.variants.each do |variant|
            if !variant.config.nil? && !variant.config.empty?
              variables = @variable_parser.parse(self, experiment.name, variant.name,
                                                 variant.config) || {}
              variables.keys.each do |key|
                # Kept sorted and unique by experiment id, as the JavaScript SDK does.
                list = (index_variables[key] ||= [])
                at = list.bsearch_index { |other| other.data.id >= experiment.id } || list.length
                list.insert(at, experiment_variables) unless list[at]&.data&.id == experiment.id
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

    def log_event(event, data)
      unless @event_logger.nil?
        @event_logger.handle_event(event, data)
      end
    rescue StandardError
      nil
    end

    def log_error(error)
      unless @event_logger.nil?
        @event_logger.handle_event(ContextEventLogger::EVENT_TYPE::ERROR, error.message)
      end
    rescue StandardError
      nil
    end

    def init_common(clock, config, data_provider, event_handler, event_logger,
                    variable_parser, audience_matcher, application = nil, environment = nil)
      @state = State.new(nil, {}, {}, {})
      @achievements = []
      @assignment_cache = {}
      @assignment_mutex = Mutex.new
      @assignments = {}
      @clock = clock.is_a?(String) ? Time.iso8601(clock) : clock
      @publish_delay = config.publish_delay
      @refresh_interval = config.refresh_interval
      @event_handler = event_handler
      @event_logger = !config.event_logger.nil? ? config.event_logger : event_logger
      @data_provider = data_provider
      @variable_parser = variable_parser
      @audience_matcher = audience_matcher
      @environment = environment
      @closed = false
      @closing = false
      @failed = false
      @ready_error = nil

      # System attributes (application/environment names from the client
      # config) seed the audience evaluation map. The collector already
      # attaches both server-side, so they are never added to the publish
      # payload; empty values are skipped so a missing key stays absent.
      @system_attributes = {}
      @system_attributes["application"] = application if application.is_a?(String) && !application.empty?
      @system_attributes["environment"] = environment if environment.is_a?(String) && !environment.empty?

      @units = {}
      @attributes = []
      @overrides = {}
      @cassignments = {}
      @assigners = {}
      @hashed_units = {}
      @pending_count = 0
      @exposures = []
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
                         variable_parser, audience_matcher, application: nil, environment: nil)
      init_common(clock, config, data_provider, event_handler, event_logger,
                  variable_parser, audience_matcher, application, environment)
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
                :full_on, :custom, :audience_mismatch, :variables, :exposed, :attrs_seq,
                :rule_override, :rule_variant, :rule_missing_unit, :rule_key

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
    @rule_override = false
    @rule_missing_unit = false
    @attrs_seq = 0
  end
end

class ExperimentVariables
  attr_accessor :data, :variables, :rules
end

class ContextCustomFieldValues
  attr_accessor :type, :value
end

class IllegalStateException < StandardError
end
