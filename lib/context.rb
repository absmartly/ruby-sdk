# frozen_string_literal: true

require_relative "hashing"
require_relative "type_utils"
require_relative "variant_assigner"
require_relative "audience_matcher"
require_relative "default_audience_deserializer"
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
  NO_RULES = ""
  NO_HOLDOUTS = {}.freeze
  private_constant :NO_HOLDOUTS

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

  # A held-out experiment publishes no exposure of its own, unless an override
  # or rule chose its variant. The holdouts covering it then expose once each,
  # in id order, from the arms pinned when the assignment was made, so a
  # refresh in between can't publish another holdout epoch (as in JS).
  def queue_exposure(assignment)
    exposure = nil
    holdout_exposures = nil
    @queue_mutex.synchronize do
      # Checked under the queue lock so an exposure cannot slip in after close
      # sealed the queue and be stranded.
      check_not_closed?

      unless assignment.exposed
        assignment.exposed = true

        if !assignment.suppressed || assignment.overridden || assignment.rule_override
          exposure = enqueue_exposure(assignment.name, assignment)
        end
        assignment.holdout_assignments&.each_with_index do |holdout_assignment, i|
          next if holdout_assignment.nil? || holdout_assignment.exposed

          holdout_assignment.exposed = true
          (holdout_exposures ||= []) << enqueue_exposure(assignment.holdouts[i].name, holdout_assignment)
        end
      end
    end
    # User callbacks run outside the lock so they can call publish/track.
    log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposure) unless exposure.nil?
    holdout_exposures&.each { |e| log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, e) }
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

    def enqueue_exposure(name, assignment)
      exposure = Exposure.new
      exposure.id = assignment.id || 0
      exposure.name = name
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
      exposure
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

    # A split rule or a holdout resolved while its unit was missing gave the
    # no-unit result; once the unit is set, unexposed ones are rebuilt. Exposed
    # ones stay, so the user never switches variant or gets a second exposure.
    def invalidate_assignments_missing_unit(unit_type)
      @assignment_mutex.synchronize do
        @assignment_cache.delete_if do |_name, assignment|
          assignment.unit_type.to_s == unit_type && !assignment.exposed &&
            (assignment.rule_missing_unit || assignment.holdout_assignments&.include?(nil))
        end
      end
    end

    # Arm 0 always holds the unit out. In a 3-arm holdout arm 1 is "full-on
    # only", so it holds out experiments that are not full-on. The arm count
    # comes from the split, never from holdoutType.
    def held_out_by?(variant, arm_count, full_on_variant)
      return true if variant == 0

      arm_count == 3 && variant == 1 && full_on_variant == 0
    end

    # Only (id, iteration) per holdout: a same-iteration seed or split edit
    # must not rebuild an exposed assignment and expose it again.
    def holdout_set_matches(entry, assignment)
      fresh = entry.holdouts
      pinned = assignment.holdouts
      return true if fresh.equal?(pinned) || (!fresh.nil? && fresh.equal?(assignment.matched_holdouts))
      return false if fresh.nil? || pinned.nil?
      return false unless fresh.length == pinned.length

      matches = fresh.each_with_index.all? do |holdout, i|
        holdout_id(holdout.id) == holdout_id(pinned[i].id) && holdout.iteration == pinned[i].iteration
      end
      # The pinned list still names the exposures, so an equivalent list from a
      # refresh is remembered apart and later reads compare it by identity.
      assignment.matched_holdouts = fresh if matches
      matches
    end

    # The arm is computed with the covered experiment's unit type, cached per
    # (holdout id, unit type) and kept while the holdout's iteration is
    # unchanged, together with the arm count it was computed against. nil
    # means the unit is not set yet; it is never cached.
    def holdout_assignment(holdout, unit_type)
      id = holdout_id(holdout.id)
      key = [id, unit_type]
      cached = @holdout_assignments&.[](key)
      return cached if cached && cached.iteration == holdout.iteration

      uid = @units[unit_type.to_sym]
      return nil if uid.nil?

      assignment = Assignment.new
      assignment.id = id
      assignment.iteration = holdout.iteration
      assignment.unit_type = unit_type
      assignment.variant = variant_assigner(unit_type, uid).assign(holdout.split, holdout.seed_hi || 0,
                                                                   holdout.seed_lo || 0)
      assignment.assigned = true
      assignment.holdout_arm_count = holdout.split.length
      (@holdout_assignments ||= {})[key] = assignment
    end

    def audience_matches(entry, assignment)
      experiment = entry.data
      key = entry.rule_key
      cached_key = assignment.rule_key || NO_RULES
      # The environment is fixed per context, so the rules text alone
      # identifies them. Equal text from a refresh is acknowledged by
      # adopting the new object, so later reads compare by identity.
      key_changed = !key.equal?(cached_key)
      if key_changed && key == cached_key
        assignment.rule_key = key
        key_changed = false
      end

      return false if key_changed && key.empty? && assignment.rule_override

      if @attrs_seq > (assignment.attrs_seq || 0) || key_changed
        attrs = attributes_map

        unless key.empty?
          pinned_missing = assignment.exposed && assignment.rule_missing_unit
          rule = resolve_rule(entry, attrs, pinned_missing)
          return false if rule&.first != assignment.rule_variant

          assignment.rule_missing_unit = rule ? rule.last : false
        end

        # A held-out unit skipped the audience when assigned, so it is not
        # evaluated here either; only a rule can take it out of suppression.
        if !assignment.rule_override && !assignment.suppressed &&
           !experiment.audience.nil? && experiment.audience.size > 0
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

    # A custom audience matcher written for v1.3.0 only implements
    # evaluate(audience, attributes); rules then use the default engine.
    def rule_matcher
      @rule_matcher ||= begin
        rule_capable = @audience_matcher.respond_to?(:parse_rules) &&
                       @audience_matcher.respond_to?(:evaluate_parsed_rules)
        rule_capable ? @audience_matcher : AudienceMatcher.new(DefaultAudienceDeserializer.new)
      end
    end

    # Returns [variant, missing_unit], or nil to fall back to normal
    # assignment (as JS and Java do for an out-of-range variant or a split
    # without one percentage per variant).
    def resolve_rule(entry, attrs, unit_pinned_missing)
      experiment = entry.data
      return nil if entry.rules.nil?

      action = rule_matcher.evaluate_parsed_rules(entry.rules, @environment, attrs)
      return nil if action.nil?

      variant_count = experiment.variants.length
      unless action.split?
        return action.variant >= 0 && action.variant < variant_count ? [action.variant, false] : nil
      end
      return nil if action.split.length != variant_count

      unit_type = experiment.unit_type
      uid = unit_type.nil? || unit_pinned_missing ? nil : @units[unit_type.to_sym]
      return [experiment.full_on_variant || 0, true] if uid.nil?

      assigner = variant_assigner(unit_type, uid)
      [assigner.assign(action.split, experiment.seed_hi, experiment.seed_lo), false]
    end

    # The state is read under the lock, so each holder sees data at least as
    # new as the previous one: a read that started before a refresh can't
    # overwrite assignments (or holdout arms) already built from newer data,
    # which would reset their exposed flag and expose them again.
    def assignment(experiment_name)
      @assignment_mutex.synchronize { cached_or_new_assignment(experiment_name, @state) }
    end

    def cached_or_new_assignment(experiment_name, state)
      assignment = @assignment_cache[experiment_name.to_s]
      exp_key = experiment_name.to_s.to_sym
      custom = @cassignments[exp_key]
      override = @overrides[exp_key]
      experiment = experiment(experiment_name.to_s, state)

      if !assignment.nil?
        if !override.nil?
          if assignment.overridden && assignment.variant == override &&
             (experiment.nil? || holdout_set_matches(experiment, assignment))
            return assignment
          end
        elsif experiment.nil?
          # A rule-won assignment came from the experiment's rules, so it is
          # rebuilt once the experiment is gone.
          return assignment if !assignment.assigned && !assignment.rule_override
        elsif (custom.nil? || assignment.rule_override || assignment.suppressed ||
               (custom == assignment.variant && (assignment.custom || assignment.exposed))) &&
              experiment_matches(experiment.data, assignment) &&
              # Inline nil check: a method call here costs ~4% on the no-holdout path.
              (experiment.holdouts.nil? ? assignment.holdouts.nil? : holdout_set_matches(experiment, assignment)) &&
              ((experiment.unconditional && assignment.rule_key.equal?(NO_RULES)) ||
               audience_matches(experiment, assignment))
          # A rule wins over a custom assignment, and a held-out unit never
          # takes one. An unexposed assignment that merely equals a new custom
          # variant is rebuilt to flag it custom.
          return assignment
        end
      end

      assignment = Assignment.new
      assignment.name = experiment_name
      assignment.eligible = true

      if !experiment.nil? && !experiment.holdouts.nil?
        data = experiment.data
        unit_type = data.unit_type
        assignment.holdouts = experiment.holdouts
        assignment.holdout_assignments = experiment.holdouts.map do |holdout|
          unit_type.nil? ? nil : holdout_assignment(holdout, unit_type)
        end
        assignment.suppressed = assignment.holdout_assignments.any? do |holdout_assignment|
          !holdout_assignment.nil? &&
            held_out_by?(holdout_assignment.variant, holdout_assignment.holdout_arm_count, data.full_on_variant)
        end
      end

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
        assignment.rule_key = experiment.rule_key
        rule = assignment.rule_key.empty? ? nil : resolve_rule(experiment, attributes_map, false)
        assignment.rule_variant = rule&.first
        assignment.rule_missing_unit = rule ? rule.last : false

        # A matching rule wins over holdout suppression, as an override does;
        # suppression skips the audience, full-on, traffic and custom paths.
        if rule
          assignment.rule_override = true
          assignment.variant = rule.first
        elsif assignment.suppressed
          assignment.variant = 0
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
    # overridden in; each experiment visited on the way is exposed. When none
    # wins, a held-out unit reads the control value of the first held-out
    # experiment rather than the default.
    def resolve_variable_value(key, default_value, expose)
      state = @state
      key = key.to_s.to_sym
      suppressed_fallback = nil
      (state.index_variables[key] || []).each do |experiment|
        assignment = assignment(experiment.data.name)
        next if assignment.variables.nil?

        queue_exposure(assignment) if expose
        if assignment.variables.key?(key) && (assignment.assigned || assignment.overridden || assignment.rule_override)
          return assignment.variables[key]
        end

        if assignment.suppressed && !assignment.overridden && !assignment.rule_override
          suppressed_fallback ||= assignment.variables
        end
      end

      return suppressed_fallback[key] if !suppressed_fallback.nil? && suppressed_fallback.key?(key)

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
      holdouts_by_id = NO_HOLDOUTS

      # Only holdouts with a numeric split and seeds can assign a unit; the
      # others are ignored, and so are holdoutIds that name none of them.
      # A custom deserializer's data may predate holdouts, so they are optional.
      holdouts = data.holdouts if data.respond_to?(:holdouts)
      holdouts.each do |holdout|
        next unless holdout.is_a?(Experiment)

        id = holdout_id(holdout.id)
        split = holdout.split
        next if id.nil? || !split.is_a?(Array) || split.empty? || !split.all?(Numeric)
        next unless [holdout.seed_hi, holdout.seed_lo].all? { |seed| seed.nil? || seed.is_a?(Integer) }

        holdouts_by_id = {} if holdouts_by_id.frozen?
        holdouts_by_id[id] = holdout
      end if holdouts.is_a?(Array)

      if data && !data.experiments.nil? && !data.experiments.empty?
        data.experiments.each do |experiment|
          experiment_custom_field_values = {}

          experiment_variables = ExperimentVariables.new
          experiment_variables.data = experiment
          rules = experiment.assignment_rules
          if rules.is_a?(String) && !rules.empty?
            experiment_variables.rule_key = rules
            experiment_variables.rules = rule_matcher.parse_rules(rules)
          else
            experiment_variables.rule_key = NO_RULES
          end
          experiment_variables.unconditional = experiment_variables.rule_key.equal?(NO_RULES) &&
                                               (experiment.audience.nil? || experiment.audience.empty?)
          holdout_ids = experiment.holdout_ids unless holdouts_by_id.empty? || !experiment.respond_to?(:holdout_ids)
          if holdout_ids.is_a?(Array) && !holdout_ids.empty?
            holdouts = holdout_ids.filter_map { |id| holdouts_by_id[holdout_id(id)] }.uniq.sort_by { |h| holdout_id(h.id) }
            experiment_variables.holdouts = holdouts unless holdouts.empty?
          end
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
                type = custom_field_value.type.to_s

                if type.start_with?("json")
                  value.value = @variable_parser.parse(self, experiment.name, custom_field_value.name, custom_value)

                elsif type.start_with?("boolean")
                  value.value = custom_value == "true"

                elsif type.start_with?("number")
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

    # Collector IDs are integers; integral floats and canonical decimal text
    # are accepted too. Other text is ignored, even when identical on both sides.
    def holdout_id(id)
      case id
      when Integer then id
      when Float then id.to_i if id.finite? && id == id.floor
      when String then Integer(id, 10) if id.match?(/\A(?:0|-?[1-9]\d*)\z/)
      end
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
      @holdout_assignments = nil
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
                :rule_override, :rule_variant, :rule_missing_unit, :rule_key,
                :suppressed, :holdouts, :matched_holdouts, :holdout_assignments, :holdout_arm_count

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
    @holdouts = nil
    @matched_holdouts = nil
  end
end

class ExperimentVariables
  attr_accessor :data, :variables, :rules, :rule_key, :unconditional, :holdouts

  # Every field is set up front so all instances share one object shape and
  # the cached read path's attribute reads stay monomorphic.
  def initialize
    @data = nil
    @variables = nil
    @rules = nil
    @rule_key = nil
    @unconditional = nil
    @holdouts = nil
  end
end

class ContextCustomFieldValues
  attr_accessor :type, :value
end

class IllegalStateException < StandardError
end
