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
  SEAL_FLUSH_PASSES = 2
  private_constant :SEAL_FLUSH_PASSES
  class EventsQueuedWhileClosing < StandardError; end
  private_constant :EventsQueuedWhileClosing

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
      @state = build_state(data_future.data_future)
      log_event(ContextEventLogger::EVENT_TYPE::READY, data_future.data_future)
    else
      set_data_failed(data_future.exception)
      log_error(data_future.exception)
    end
  end

  def set_data(data_future)
    ready_data = nil
    failure = nil
    # Skip building a payload a refresh has already superseded; ready? is
    # rechecked under the lock before a built snapshot is installed.
    state = data_future.success? && !ready? ? build_state(data_future.data_future) : nil
    @ready_mutex.synchronize do
      # A refresh may already have installed data while the initial fetch was
      # in flight: keep it, so a late success doesn't replace newer data and
      # a late failure is only logged.
      if ready?
        failure = data_future.exception unless data_future.success?
      elsif state
        @state = state
      else
        failure = data_future.exception
        set_data_failed(failure)
      end
      ready_data = @state.data unless @failed
      @ready_condvar.broadcast
    end

    # User callbacks run outside the readiness lock so they may call
    # wait_until_ready. A context made ready by a refresh logs "ready" too.
    log_error(failure) unless failure.nil?
    log_event(ContextEventLogger::EVENT_TYPE::READY, ready_data) unless ready_data.nil?
  end

  def wait_until_ready(timeout = nil)
    # Called from a variable parser while this thread builds the data that
    # would make the context ready: waiting here could never finish.
    return self if @ready_mutex.synchronize { @building_threads.key?(Thread.current) }

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
    !@closed && @sealing.positive?
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
    user_attributes
  end

  def experiments
    check_ready?(false)
    check_not_closed_by_close?

    @state.data.experiments.map(&:name)
  end

  def set_override(experiment_name, variant)
    check_not_closed_by_close?

    @overrides[experiment_name.to_s.to_sym] = variant
  end

  def set_overrides(overrides)
    check_not_closed_by_close?

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

    if Absmartly::TypeUtils.numeric?(uid)
      trimmed = uid
    else
      # Like v1.3.0, any other value (Symbol, session id, UUID object) is
      # stored as its to_s text.
      uid = uid.respond_to?(:to_str) ? uid.to_str : uid.to_s
      trimmed = uid.strip
    end

    previous = @units[unit_type.to_sym]
    # Compared as text, so 123456 and "123456" are the same unit, as in v1.3.0.
    if !previous.nil? && previous.to_s != trimmed.to_s
      raise IllegalStateException.new("Unit '#{unit_type}' already set.")
    end

    if trimmed.is_a?(String) && trimmed.empty?
      raise IllegalStateException.new("Unit '#{unit_type}' UID must not be blank.")
    end

    if previous.nil?
      @units[unit_type.to_sym] = trimmed
      invalidate_assignments_missing_unit(unit_type.to_s)
    end
    trimmed.to_s
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
    return if assignment.exposed

    claimed = false
    begin
      Thread.handle_interrupt(Object => :never) do
        @queue_mutex.synchronize do
          check_not_closed?
          unless assignment.exposed || @exposing.key?(assignment)
            @exposing[assignment] = true
            claimed = true
          end
        end
      end
      return unless claimed

      # Only this assignment is claimed, without holding a lock over the
      # supplied clock; distinct nested or concurrent exposures can proceed.
      exposed_at = @clock.to_i
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
          exposure.exposed_at = exposed_at
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
    ensure
      if claimed
        Thread.handle_interrupt(Object => :never) do
          @queue_mutex.synchronize { @exposing.delete(assignment) }
        end
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
    check_not_closed?

    flush
  end

  def refresh
    check_not_closed?
    return nil if @failed

    data_future = @data_provider.context_data
    if data_future.success?
      state = build_state(data_future.data_future)
      # Committed under the readiness lock, so a waiter on a context created
      # asynchronously wakes, and an initial fetch that failed while this
      # refresh was in flight no longer leaves the context failed.
      Thread.handle_interrupt(Object => :never) do
        @ready_mutex.synchronize do
          @state = state
          @failed = false
          @data_failed = nil
          @ready_error = nil
          @ready_condvar.broadcast
        end
      end
      log_event(ContextEventLogger::EVENT_TYPE::REFRESH, data_future.data_future)
    else
      log_error(data_future.exception)
    end
  end

  # Publishes pending events, then seals the context and logs "close", as in
  # v1.3.0: a publish the collector rejects is logged as an error and the
  # context is still sealed. A publisher that raises propagates the error and
  # leaves the context open with the events queued.
  def close
    seal(ContextEventLogger::EVENT_TYPE::CLOSE)
  end

  # Like close, but as the JavaScript SDK does: if the final publish fails, the
  # failure is raised and the context stays open with the events queued, so
  # finalize can be retried. Logs "finalize" once sealed, and set_override,
  # set_overrides and experiments keep working afterwards.
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
      # events queued by the callback are still sent before finalizing. A seal
      # that is already running does not claim it, so the request survives if
      # that seal fails or gives up.
      if @publish_mutex.owned?
        @close_pending = event_type
        @close_requests += 1
        return nil
      end

      close = event_type == ContextEventLogger::EVENT_TYPE::CLOSE
      @queue_mutex.synchronize { @sealing += 1 }
      begin
        # One extra pass sends events a logger callback queued during the
        # first publish; after that raise with the remaining events queued,
        # so a callback can't keep close publishing forever or lose events.
        SEAL_FLUSH_PASSES.times do |pass|
          # close drops a batch the collector rejected, as in v1.3.0, but only
          # that batch; anything queued meanwhile is still sent or kept.
          result = flush(sealing: true, drop_rejected: close)
          last_pass = pass == SEAL_FLUSH_PASSES - 1
          raise_publish_failure(result) if !close && publish_failed?(result)

          sealed = @queue_mutex.synchronize do
            next :done if @closed

            unless @exposures.empty? && @achievements.empty?
              raise EventsQueuedWhileClosing.new("Events queued while closing; retry close or finalize") if last_pass

              next :retry
            end

            @closed = true
            @sealed_by = event_type
            :sealed
          end
          return nil if sealed == :done
          next if sealed == :retry

          logged = log_event(event_type, nil)
          return event_type == ContextEventLogger::EVENT_TYPE::CLOSE ? logged : nil
        end
        nil
      ensure
        @queue_mutex.synchronize { @sealing -= 1 }
      end
    end

    # sealing: this flush is a seal's own pass, so it neither starts another
    # seal nor claims a deferred one. Any other publish (on any thread) may.
    def flush(sealing: false, drop_rejected: false)
      dropped, failure = drop_if_failed(sealing)
      return failure if dropped

      # Serialize publishes so a queued event is part of at most one in-flight
      # request; on failure the events stay queued for the next attempt.
      # A logger callback that calls publish from inside a publish must not
      # deadlock or re-send the in-flight snapshot; the outer call owns it.
      return nil if @publish_mutex.owned?

      claimed = nil
      result = @publish_mutex.synchronize do
        exposures = achievements = nil
        event_count = 0
        # Failure installation and recovery both take this lock. Keep the
        # decision and snapshot together, but never hold it across publishing.
        dropped, failure = @ready_mutex.synchronize do
          failed_result = drop_if_failed(sealing, ready_locked: true)
          unless failed_result.first
            @queue_mutex.synchronize do
              exposures = @exposures.dup
              achievements = @achievements.dup
              event_count = exposures.size + achievements.size
            end
          end
          failed_result
        end
        next failure if dropped

        if event_count.zero?
          claimed = take_close_pending unless sealing
          next nil
        end

        # Captured before the handler runs, so a handler that mutates the
        # payload it was given can't change which queued events are removed.
        sent = {}.compare_by_identity
        exposures.each { |sent_event| sent[sent_event] = true }
        achievements.each { |sent_event| sent[sent_event] = true }

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

        if publish_failed?(response)
          if response.is_a?(Exception)
            log_error(response)
          elsif response.respond_to?(:exception) && response.exception
            log_error(response.exception)
          else
            log_error(StandardError.new("Publish failed (status=#{response.respond_to?(:status) ? response.status : 'unknown'})"))
          end
          remove_published(sent) if drop_rejected
          response
        else
          log_event(ContextEventLogger::EVENT_TYPE::PUBLISH, event)
          remove_published(sent)
          # Claim a deferred close while still holding the lock, so only this
          # successful publish can carry it out; a request made by another
          # thread after a rejected publish waits for its own success.
          claimed = take_close_pending unless sealing
          response
        end
      end

      run_deferred_seal(claimed) if claimed
      result
    end

    # A failed context drops its queued events. Rechecked under the readiness
    # lock, which a recovering refresh also holds while it clears @failed, so
    # goals tracked after recovery are never dropped by a publish that saw the
    # context failed. publish gets the load error, as in v1.3.0; a seal's own
    # pass gets nil, since dropping them is not a publish failure.
    def drop_if_failed(sealing, ready_locked: false)
      return [false, nil] unless @failed
      return @ready_mutex.synchronize { drop_if_failed(sealing, ready_locked: true) } unless ready_locked

      @queue_mutex.synchronize do
        @exposures = []
        @achievements = []
        @pending_count = 0
      end
      [true, sealing ? nil : @data_failed]
    end

    # A failed-context publish can clear the queue while a request is in flight.
    # Remove only the actual objects sent, never newer events at their positions.
    def remove_published(sent)
      @queue_mutex.synchronize do
        @exposures.delete_if { |event| sent.key?(event) }
        @achievements.delete_if { |event| sent.key?(event) }
        @pending_count = @exposures.size + @achievements.size
      end
    end

    def take_close_pending
      return nil unless @close_pending

      claimed = [@close_pending, @close_requests]
      @close_pending = false
      claimed
    end

    def run_deferred_seal((event_type, request))
      seal(event_type)
    rescue StandardError => error
      # A deferred seal that did not finish (events still queued, or its own
      # publish rejected or raised) stays pending for the next successful
      # publish, unless a newer request was made meanwhile (even one another
      # publish has already claimed). Only "events still queued" lets this
      # publish return.
      @publish_mutex.synchronize do
        @close_pending = event_type unless @closed || @close_requests != request
      end
      raise unless error.is_a?(EventsQueuedWhileClosing)
    end

    def publish_failed?(result)
      result.is_a?(Exception) ||
        (result.respond_to?(:exception) && result.exception) ||
        (result.respond_to?(:success?) && !result.success?)
    end

    def raise_publish_failure(result)
      if result.is_a?(StandardError)
        raise result
      elsif result.is_a?(Exception)
        raise StandardError.new(result.message), cause: result
      elsif result.respond_to?(:exception) && result.exception
        raise_publish_failure(result.exception)
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

    # v1.3.0's close made these raise; finalize, like the JavaScript SDK, does not.
    def check_not_closed_by_close?
      check_not_closed? if @sealed_by == ContextEventLogger::EVENT_TYPE::CLOSE
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
    # The latest value per name, keyed as the caller set it. Private so an
    # override of the public get_attributes doesn't change matcher inputs.
    def user_attributes
      result = {}
      @attributes.each { |attr| result[attr.name] = attr.value }
      result
    end

    def attributes_map
      # User attributes keep the caller's key, as v1.3.0 passed them to custom
      # matchers. A system entry is added only when no user attribute has that
      # name as a String or Symbol, the forms audience conditions can read.
      user = user_attributes
      attrs = {}
      @system_attributes.each do |name, value|
        attrs[name] = value unless user.key?(name) || user.key?(name.to_sym)
      end
      attrs.merge!(user)
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

    def assignment(experiment_name, state = @state)
      @assignment_mutex.synchronize { cached_or_new_assignment(experiment_name, state) }
    end

    def cached_or_new_assignment(experiment_name, state)
      assignment = @assignment_cache[experiment_name.to_s]
      exp_key = experiment_name.to_s.to_sym
      custom = @cassignments[exp_key]
      override = @overrides[exp_key]
      experiment = experiment(experiment_name.to_s, state)

      # Built from the empty snapshot of a failed context that a refresh has
      # since recovered with the experiment: resolved again against the
      # recovered data. Untagged only once a replacement is cached, so a
      # rebuild that raises leaves it ineligible for reuse.
      # (The failed snapshot has no experiments, so a read on it never matches.)
      if !assignment.nil? && !experiment.nil? && !@failed_built.empty? && @failed_built.key?(assignment)
        assignment = nil
      end

      if !assignment.nil?
        if !override.nil?
          return assignment if assignment.overridden && assignment.variant == override
        elsif experiment.nil?
          # A rule-won assignment came from the experiment's rules, so it is
          # rebuilt once the experiment is gone.
          return assignment if !assignment.assigned && !assignment.rule_override && !assignment.overridden
        elsif (custom.nil? || assignment.rule_override ||
               (custom == assignment.variant && (assignment.custom || assignment.exposed))) &&
              experiment_matches(experiment.data, assignment) &&
              ((experiment.unconditional && assignment.rule_key.equal?(NO_RULES)) ||
               audience_matches(experiment, assignment))
          # A rule wins over a custom assignment. An unexposed assignment that
          # merely equals a new custom variant is rebuilt to flag it custom.
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
        assignment.rule_key = experiment.rule_key
        rule = assignment.rule_key.empty? ? nil : resolve_rule(experiment, attributes_map, false)
        assignment.rule_variant = rule&.first
        assignment.rule_missing_unit = rule ? rule.last : false

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

      failed_built = state.equal?(@failed_state)
      # A read that finishes after a refresh recovered the context must not
      # replace what was resolved against the recovered data, unless that
      # data lacks the experiment too and would resolve it the same way.
      if failed_built && !@state.equal?(@failed_state) && !experiment(experiment_name.to_s).nil?
        return assignment
      end

      replaced = @assignment_cache[experiment_name.to_s]
      if failed_built || (!@failed_built.empty? && @failed_built.key?(replaced))
        # Tagged and untagged together with the cache write, so an interrupt
        # can't leave a failed assignment cached but untagged (reusable after
        # recovery) or a tag without its entry; the tags never outgrow the cache.
        Thread.handle_interrupt(Object => :never) do
          @failed_built.delete(replaced) unless replaced.nil?
          @failed_built[assignment] = true if failed_built
          @assignment_cache[experiment_name.to_s] = assignment
        end
      else
        @assignment_cache[experiment_name.to_s] = assignment
      end
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

    # Builds the snapshot for data, calling the variable parser; callers run
    # it outside the readiness lock so a parser may call wait_until_ready.
    # The membership bookkeeping defers asynchronous interrupts (Timeout,
    # Thread#raise), so one landing while it waits for the lock can't leave
    # this thread registered or unbalanced. The parsing keeps the caller's
    # interrupt mask: interruptible by default, deferred if the caller masked.
    # An interrupt landing in the few instructions between the parse and the
    # cleanup mask can still skip the cleanup; closing that gap would need a
    # mask around the parse, which overrides the caller's own.
    def build_state(data)
      thread = Thread.current
      registered = false
      begin
        Thread.handle_interrupt(Object => :never) do
          @ready_mutex.synchronize { @building_threads[thread] = (@building_threads[thread] || 0) + 1 }
          registered = true
        end
        build_state_maps(data)
      ensure
        if registered
          Thread.handle_interrupt(Object => :never) do
            @ready_mutex.synchronize do
              @building_threads[thread] -= 1
              @building_threads.delete(thread) if @building_threads[thread].zero?
            end
          end
        end
      end
    end

    def build_state_maps(data)
      index = {}
      index_variables = {}
      custom_fields = {}

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

      State.new(data, index, index_variables, custom_fields)
    end

    def set_data_failed(exception)
      @data_failed = exception
      @ready_error = exception
      @state = @failed_state = State.new(ContextData.new, {}, {}, {})
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
      @failed_built = {}.compare_by_identity
      @assignment_mutex = Mutex.new
      @exposing = {}.compare_by_identity
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
      @sealing = 0
      @failed = false
      @ready_error = nil
      @sealed_by = nil
      @building_threads = {}

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
      @close_requests = 0

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
  attr_accessor :data, :variables, :rules, :rule_key, :unconditional
end

class ContextCustomFieldValues
  attr_accessor :type, :value
end

class IllegalStateException < StandardError
end
