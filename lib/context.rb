# frozen_string_literal: true

# Fiber.current and Fiber#alive? before Ruby 3.1.
require "fiber"
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
  NO_HOLDOUTS = {}.freeze
  private_constant :NO_HOLDOUTS
  VARIABLE_WALK_ATTEMPTS = 3
  private_constant :VARIABLE_WALK_ATTEMPTS

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
    # wait_until_ready.
    log_error(failure) unless failure.nil?
    log_event(ContextEventLogger::EVENT_TYPE::READY, ready_data) unless ready_data.nil?
  end

  def wait_until_ready(timeout = nil)
    # Called from a variable parser while this thread builds the data that
    # would make the context ready: waiting here could never finish.
    return self if building?

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

    while true # rubocop:disable Style/InfiniteLoop -- no block allocation on the read path
      assignment = assignment(experiment_name)
      # set_unit may evict it between the lookup and the exposure claim:
      # then it is resolved again, so the variant served is the one exposed.
      return assignment.variant unless claim_and_queue_exposure(assignment, experiment_name) == :evicted
    end
  end

  # A held-out experiment publishes no exposure of its own, unless an override
  # or rule chose its variant. The holdouts covering it then expose once each,
  # in id order, from the arms pinned when the assignment was made, so a
  # refresh in between can't publish another holdout epoch (as in JS).
  def queue_exposure(assignment)
    result = nil
    claim_and_queue_exposure(assignment) { |logged| result = logged }
    result
  end

  def peek_treatment(experiment_name)
    check_ready?(true)

    assignment(experiment_name).variant
  end

  alias peek peek_treatment

  # Maps each variable key to one experiment name, as in v1.3.0: the
  # lowest-id experiment defining it, which is not necessarily the one whose
  # value variable_value returns (see variable_keys_list).
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
    # SDK reads check the cache under the assignment lock; a direct
    # queue_exposure call has nothing to check and may already hold it (from a
    # custom matcher), so it skips it.
    def with_assignment_lock_if(locked, &block)
      locked ? @assignment_mutex.synchronize(&block) : yield
    end

    # Claims and queues assignment's exposure. With experiment_name, the claim
    # is taken only while the assignment is still the cached one for that
    # experiment (checked under the assignment lock, which set_unit also
    # takes to evict), and a no-unit split assignment whose unit has since
    # been set counts as stale; then nothing is queued and :evicted is
    # returned so the caller resolves it again. Returns nil otherwise, never
    # the logger's result (that is passed to the block).
    def claim_and_queue_exposure(assignment, experiment_name = nil)
      return if assignment.exposed

      claimed = false
      begin
        loop do
          status = nil
          # Waiting for the assignment lock stays interruptible; only the claim
          # bookkeeping under it is masked.
          with_assignment_lock_if(experiment_name) do
            Thread.handle_interrupt(Object => :never) do
              @queue_mutex.synchronize do
                check_not_closed?
                owner = @exposing[assignment]
                status =
                  if owner
                    # Another thread's exposure is in flight; this thread's own
                    # (a reentrant read from its clock) uses the outer one.
                    owner.equal?(Thread.current) ? :reentered : :waiting
                  elsif assignment.exposed
                    :exposed
                  # On the SDK's read paths (experiment_name given), a no-unit
                  # split assignment whose unit has since been set is stale too
                  # (a failed exposure left it cached): resolved again. A
                  # direct queue_exposure call queues what it is given.
                  elsif experiment_name.nil? ||
                        (@assignment_cache[experiment_name.to_s].equal?(assignment) && !unit_now_set?(assignment))
                    @exposing[assignment] = Thread.current
                    claimed = true
                    :claimed
                  else
                    :evicted
                  end
              end
            end
          end
          return :evicted if status == :evicted
          break unless status == :waiting

          @queue_mutex.synchronize do
            owner = @exposing[assignment]
            @exposure_condvar.wait(@queue_mutex) if owner && !owner.equal?(Thread.current)
          end
        end
        return unless claimed

        # Only this assignment is claimed, without holding a lock over the
        # supplied clock; distinct nested or concurrent exposures can proceed.
        exposed_at = @clock.to_i
        exposure = nil
        holdout_exposures = nil
        @queue_mutex.synchronize do
          # Checked under the queue lock so an exposure cannot slip in after close
          # sealed the queue and be stranded.
          check_not_closed?

          unless assignment.exposed
            assignment.exposed = true

            # A held-out experiment publishes no exposure of its own, unless an
            # override or rule chose its variant. The holdouts covering it then
            # expose once each, in id order, from the arms pinned when the
            # assignment was made (as in JS).
            if !assignment.suppressed || assignment.overridden || assignment.rule_override
              exposure = enqueue_exposure(assignment.name, assignment, exposed_at)
            end
            assignment.holdout_assignments&.each_with_index do |holdout_assignment, i|
              next if holdout_assignment.nil? || holdout_assignment.exposed

              holdout_assignment.exposed = true
              (holdout_exposures ||= []) << enqueue_exposure(assignment.holdouts[i].name, holdout_assignment, exposed_at)
            end
          end
        end
      ensure
        # Only the claim is released here (no assignment lock, so an unwinding
        # timeout is not held up). A no-unit assignment left unexposed after its
        # unit was set is rebuilt by the next read (see cached_or_new_assignment).
        if claimed
          Thread.handle_interrupt(Object => :never) do
            @queue_mutex.synchronize do
              @exposing.delete(assignment)
              @exposure_condvar.broadcast
            end
          end
        end
      end
      # User callbacks run outside the lock so they can call publish/track.
      logged = log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposure) unless exposure.nil?
      holdout_exposures&.each { |e| log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, e) }
      yield logged if block_given? && !exposure.nil?
      nil
    end

    def seal(event_type)
      return nil if @closed

      # Called from a logger callback while a publish is in flight: defer so the
      # events queued by the callback are still sent before finalizing. A seal
      # that is already running does not claim it, so the request survives if
      # that seal fails or gives up.
      if @publish_mutex.owned?
        @deferred_mutex.synchronize do
          @close_pending = event_type
          @close_requests += 1
        end
        return nil
      end

      close = event_type == ContextEventLogger::EVENT_TYPE::CLOSE
      registered = false
      begin
        Thread.handle_interrupt(Object => :never) do
          @queue_mutex.synchronize { @sealing += 1 }
          registered = true
        end
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

            Thread.handle_interrupt(Object => :never) do
              @sealed_by = event_type
              @closed = true
            end
            :sealed
          end
          return nil if sealed == :done
          next if sealed == :retry

          logged = log_event(event_type, nil)
          return close ? logged : nil
        end
        nil
      ensure
        if registered
          Thread.handle_interrupt(Object => :never) do
            @queue_mutex.synchronize { @sealing -= 1 }
          end
        end
      end
    end

    # sealing: this flush is a seal's own pass, so it neither starts another
    # seal nor claims a deferred one. Any other publish (on any thread) may.
    def flush(sealing: false, drop_rejected: false)
      dropped, failure = @failed ? @ready_mutex.synchronize { drop_if_failed(sealing) } : [false, nil]
      return failure if dropped

      # Serialize publishes so a queued event is part of at most one in-flight
      # request; on failure the events stay queued for the next attempt.
      # A logger callback that calls publish from inside a publish must not
      # deadlock or re-send the in-flight snapshot; the outer call owns it.
      return nil if @publish_mutex.owned?

      claimed = nil
      begin
        result = @publish_mutex.synchronize do
          exposures = achievements = nil
          sent = nil
          event_count = 0
          # Failure installation and recovery both take this lock. Keep the
          # decision and snapshot together, but never hold it across publishing.
          dropped, failure = @ready_mutex.synchronize do
            failed_result = drop_if_failed(sealing)
            unless failed_result.first
              @queue_mutex.synchronize do
                exposures = @exposures.dup
                achievements = @achievements.dup
                event_count = exposures.size + achievements.size
                # Which arrays were sent and how much of each: the queues only
                # grow by appending or are replaced whole, so a handler that
                # mutates its payload can't change what is removed.
                sent = [@exposures, exposures.size, @achievements, achievements.size]
              end
            end
            failed_result
          end
          next failure if dropped

          if event_count.zero?
            # Assigned under the mask, so an interrupt can't land between
            # clearing the request and recording that this publish holds it.
            Thread.handle_interrupt(Object => :never) { claimed = take_close_pending } unless sealing
            next nil
          end

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
            # Assigned under the mask, so an interrupt can't land between
            # clearing the request and recording that this publish holds it.
            Thread.handle_interrupt(Object => :never) { claimed = take_close_pending } unless sealing
            response
          end
        end

        if claimed
          claimed = nil if run_deferred_seal(claimed)
        end
        result
      ensure
        # A deferred seal claimed by this publish that did not finish stays
        # pending for the next successful publish: one not started (an
        # interrupt landed after the claim), one that left events queued, or
        # one whose own publish was rejected, raised or was interrupted (a
        # Timeout or Thread#kill). Any error still propagates.
        restore_close_pending(claimed) if claimed
      end
    end

    # A failed context drops its queued events. Called under the readiness
    # lock, which a recovering refresh also holds while it clears @failed, so
    # goals tracked after recovery are never dropped by a publish that saw the
    # context failed. publish gets the load error, as in v1.3.0; a seal's own
    # pass gets nil, since dropping them is not a publish failure.
    def drop_if_failed(sealing)
      return [false, nil] unless @failed

      @queue_mutex.synchronize do
        @exposures = []
        @achievements = []
        @pending_count = 0
      end
      [true, sealing ? nil : @data_failed]
    end

    # Removes the sent prefix of each queue, unless a failed-context publish
    # replaced that queue while the request was in flight (then the batch is
    # already gone and the new queue holds only newer events).
    def remove_published((exposures, exposure_count, achievements, achievement_count))
      @queue_mutex.synchronize do
        @exposures.shift(exposure_count) if @exposures.equal?(exposures)
        @achievements.shift(achievement_count) if @achievements.equal?(achievements)
        @pending_count = @exposures.size + @achievements.size
      end
    end

    def take_close_pending
      @deferred_mutex.synchronize do
        next nil unless @close_pending

        claimed = [@close_pending, @close_requests]
        @close_pending = false
        claimed
      end
    end

    # True once the seal finished; false when events were still queued.
    def run_deferred_seal(claimed)
      seal(claimed.first)
      true
    rescue EventsQueuedWhileClosing
      false
    end

    # Unless the context sealed or a newer request was made meanwhile (even
    # one another publish has already claimed).
    def restore_close_pending((event_type, request))
      Thread.handle_interrupt(Object => :never) do
        @deferred_mutex.synchronize do
          @close_pending = event_type unless @closed || @close_requests != request
        end
      end
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

    # Called under the queue lock; exposed_at is read before taking it, since a
    # supplied clock may call back into the context.
    def enqueue_exposure(name, assignment, exposed_at)
      exposure = Exposure.new
      exposure.id = assignment.id || 0
      exposure.name = name
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
      exposure
    end

    def check_not_closed?
      if @closed
        raise IllegalStateException.new("ABSmartly Context is closed")
      end
    end

    # After finalize these still work, as in the JavaScript SDK.
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

    # The built-in evaluator reads a name as a String or a Symbol, so it gets
    # one entry per name: the latest value set under either spelling.
    def evaluator_attributes
      attrs = {}
      @system_attributes.each { |name, value| attrs[name] = value }
      @attributes.each { |attr| attrs[attr.name.to_s] = attr.value }
      attrs
    end

    # Custom matchers get the caller's keys (as in v1.3.0); the built-in one
    # gets the latest value per name.
    def matcher_attributes(matcher)
      matcher.instance_of?(AudienceMatcher) ? evaluator_attributes : attributes_map
    end

    # A built-in audience matcher is also the rule matcher, and the evaluator
    # never changes its input, so the map built for the rules is reused.
    def audience_attributes(rule_attrs)
      return rule_attrs if !rule_attrs.nil? && @audience_matcher.instance_of?(AudienceMatcher)

      matcher_attributes(@audience_matcher)
    end

    # A split rule or a holdout resolved while its unit was missing gave the
    # no-unit result; once the unit is set, unexposed ones are rebuilt. Exposed ones
    # stay, so the user never switches variant or gets a second exposure.
    # One being exposed right now (its clock is running) is kept: it is
    # about to be queued with its variant, so evicting it would serve one
    # variant and expose two. If that exposure fails, the next read or claim
    # finds it stale and resolves it again.
    def invalidate_assignments_missing_unit(unit_type)
      @assignment_mutex.synchronize do
        exposing = @queue_mutex.synchronize { @exposing.dup }
        @assignment_cache.delete_if do |_name, assignment|
          assignment.unit_type.to_s == unit_type && !assignment.exposed && missing_unit?(assignment) &&
            !exposing.key?(assignment)
        end
      end
    end

    # A no-unit split assignment whose unit has since been set, that is not
    # exposed and not being exposed: set_unit skipped evicting it because its
    # exposure was in progress, and that exposure did not complete.
    def stale_missing_unit?(assignment)
      return false unless unit_now_set?(assignment)

      !exposed_or_exposing?(assignment)
    end

    # Read together under the queue lock: an exposure completing sets exposed
    # and releases its claim under that lock, so a reader can't see neither.
    def exposed_or_exposing?(assignment)
      # exposed only moves false -> true: the positive result is stable.
      return true if assignment.exposed

      @queue_mutex.synchronize { assignment.exposed || @exposing.key?(assignment) }
    end

    # Resolved while its unit was missing: a no-unit split rule, or a holdout
    # whose arm could not be computed yet.
    def missing_unit?(assignment)
      assignment.rule_missing_unit || (!assignment.holdout_assignments.nil? && assignment.holdout_assignments.include?(nil))
    end

    def unit_now_set?(assignment)
      missing_unit?(assignment) && !assignment.unit_type.nil? && !@units[assignment.unit_type.to_sym].nil?
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
        rule_attrs = nil
        unless key.empty?
          # Exposed, or being exposed right now (its clock may set the unit):
          # the no-unit variant stays, so a unit arriving can't switch it.
          pinned_missing = assignment.rule_missing_unit && exposed_or_exposing?(assignment)
          rule_attrs = matcher_attributes(rule_matcher)
          rule = resolve_rule(entry, rule_attrs, pinned_missing)
          return false if rule&.first != assignment.rule_variant

          assignment.rule_missing_unit = rule ? rule.last : false
        end

        # A held-out unit skipped the audience when assigned, so it is not
        # evaluated here either; only a rule can take it out of suppression.
        if !assignment.rule_override && !assignment.suppressed &&
           !experiment.audience.nil? && experiment.audience.size > 0
          match = @audience_matcher.evaluate(experiment.audience, audience_attributes(rule_attrs))
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

      # Built from the empty snapshot of a failed context that a refresh has
      # since recovered with the experiment: resolved again against the
      # recovered data. The marker stays on the old assignment, so a rebuild
      # that raises leaves it ineligible for reuse.
      # (The failed snapshot has no experiments, so a read on it never matches.)
      if @failed_marked && !assignment.nil? && !experiment.nil? &&
         assignment.instance_variable_get(:@failed_snapshot)
        assignment = nil
      end
      # Inline guard: only an unexposed no-unit result can be stale, and the
      # check itself takes the queue lock.
      if !assignment.nil? && !assignment.exposed &&
         (assignment.rule_missing_unit || assignment.holdout_assignments&.include?(nil)) &&
         stale_missing_unit?(assignment)
        assignment = nil
      end

      if !assignment.nil?
        if !override.nil?
          if assignment.overridden && assignment.variant == override &&
             (experiment.nil? || holdout_set_matches(experiment, assignment))
            return assignment
          end
        elsif experiment.nil?
          # A rule-won assignment came from the experiment's rules, so it is
          # rebuilt once the experiment is gone.
          return assignment if !assignment.assigned && !assignment.rule_override && !assignment.overridden
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
        rule_attrs = assignment.rule_key.empty? ? nil : matcher_attributes(rule_matcher)
        rule = rule_attrs.nil? ? nil : resolve_rule(experiment, rule_attrs, false)
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
            match = @audience_matcher.evaluate(data.audience, audience_attributes(rule_attrs))
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

      # Provenance belongs to the new assignment before the single cache
      # write. An interrupted replacement leaves the old assignment marked;
      # a marker on an uncached replacement has no effect on later reads.
      if failed_built
        assignment.instance_variable_set(:@failed_snapshot, true)
        @failed_marked = true
      end
      @assignment_cache[experiment_name.to_s] = assignment
      assignment
    end

    # As java-sdk Context.getVariableAssignment resolves a key shared by
    # several experiments: the first one, in experiment id order, that the
    # unit is assigned to, overridden in or rule-assigned in wins, and only
    # that one is exposed. A winner whose variant lacks the key gives the
    # default; the walk never moves past it. When none wins, a held-out unit
    # reads the first held-out experiment (control, or the default if its
    # control lacks the key). A non-peek read still exposes the holdouts of
    # each candidate it visits, as java-sdk does.
    def resolve_variable_value(key, default_value, expose)
      key = key.to_s.to_sym
      winner = nil
      attempts = 0
      while true # rubocop:disable Style/InfiniteLoop -- no block allocation on the read path
        # A refresh that keeps landing mid-walk (from a matcher or logger
        # callback) can't make a read loop: after the last attempt it gives the
        # default and exposes nothing, as no snapshot stood still for it.
        return default_value if attempts >= VARIABLE_WALK_ATTEMPTS

        attempts += 1
        state = @state
        # The holdouts to expose are collected per read, never per context,
        # so concurrent reads can't share them; the list is created only at
        # the first candidate with a holdout still to expose.
        winner = variable_assignment(key, expose, state)
        visited = nil
        winner, visited = winner if winner.is_a?(Array)
        # A refresh during the walk can move the key to other experiments.
        # The candidates, the winner and the holdouts exposed must come from
        # one snapshot, so nothing is exposed until the walk stands.
        next unless @state.equal?(state)

        unless visited.nil?
          i = 0
          # A holdout's logger callback may refresh; the walk then starts again
          # instead of exposing the rest of the old one.
          while i < visited.length && @state.equal?(state)
            queue_holdout_exposures(visited[i])
            i += 1
          end
          next unless @state.equal?(state)
        end
        break if winner.nil? || !expose || winner.exposed
        # The unit was set in between, so the walk may now pick another
        # candidate: it starts again, as java-sdk's settleExposure does.
        break unless claim_and_queue_exposure(winner, winner.name) == :evicted
      end
      return default_value if winner.nil? || winner.variables.nil? || !winner.variables.key?(key)

      winner.variables[key]
    end

    # Returns the winner, or, when exposing and a visited candidate still has
    # a holdout to expose, [winner, those candidates] (only then allocated);
    # the caller exposes them once the walk stands.
    def variable_assignment(key, expose, state = @state)
      candidates = state.index_variables[key]
      return nil if candidates.nil?

      visited = nil
      suppressed_fallback = nil
      i = 0
      # An index loop, not each: no block frame per candidate on the read path.
      while i < candidates.length
        # Resolved from the state current under the assignment lock, so a read
        # that a refresh overtook can't reinstall an old assignment.
        assignment = assignment(candidates[i].data.name)
        # As in java-sdk, each visited candidate's holdouts, the winner's
        # included, are queued before the winner's own exposure.
        # Inline guard: most candidates have no holdouts, and an exposed one
        # has exposed them, unless it is an override with an arm still missing
        # or not yet exposed (see queue_holdout_exposures).
        if expose && !assignment.holdout_assignments.nil? &&
           (!assignment.exposed || assignment.overridden) && holdouts_pending?(assignment)
          (visited ||= []) << assignment
        end
        if assignment.assigned || assignment.overridden || assignment.rule_override
          return visited ? [assignment, visited] : assignment
        end

        suppressed_fallback ||= assignment if assignment.suppressed
        i += 1
      end
      visited ? [suppressed_fallback, visited] : suppressed_fallback
    end

    # Whether a candidate has a holdout arm still to expose (or, for an
    # override, one still to resolve). A warm read past an exposed loser then
    # collects nothing.
    def holdouts_pending?(assignment)
      arms = assignment.holdout_assignments
      i = 0
      while i < arms.length
        arm = arms[i]
        if arm.nil?
          # A missing arm is pending only for an override whose unit is now set.
          unit_type = assignment.unit_type
          return true if assignment.overridden && !unit_type.nil? && !@units[unit_type.to_sym].nil?
        elsif !arm.exposed
          return true
        end

        i += 1
      end
      false
    end

    # Replaces the arms of an override still missing them, once its unit is
    # set; the holdout arm cache is written under the assignment lock.
    def resolve_late_holdout_arms(assignment)
      arms = assignment.holdout_assignments
      return unless unit_now_set?(assignment) && arms.include?(nil)

      @assignment_mutex.synchronize do
        arms = assignment.holdout_assignments
        # The live holdouts (a refresh's equivalent list, if any): the arms are
        # decided now, so they and their exposures' names come from those, as
        # java-sdk resolves an override's holdouts against the installed data.
        holdouts = assignment.matched_holdouts || assignment.holdouts
        if arms.include?(nil)
          assignment.holdout_assignments = arms.each_with_index.map do |arm, i|
            arm || holdout_assignment(holdouts[i], assignment.unit_type)
          end
          assignment.holdouts = holdouts
        end
      end
    end

    # Exposes the holdouts covering a visited candidate, from the arms pinned
    # in its assignment, without exposing the candidate itself.
    def queue_holdout_exposures(assignment)
      return if assignment.exposed && !assignment.overridden

      # As java-sdk resolves an override's holdouts live on each visit, an
      # arm an override could not get before its unit was set is resolved
      # once the unit is, so its holdout is exposed even after the override.
      resolve_late_holdout_arms(assignment) if assignment.overridden
      holdout_assignments = assignment.holdout_assignments
      return if holdout_assignments.nil?

      # Checked again under the lock; this keeps warm reads off the clock and lock.
      return if holdout_assignments.all? { |holdout_assignment| holdout_assignment.nil? || holdout_assignment.exposed }

      exposed_at = @clock.to_i
      holdout_exposures = nil
      @queue_mutex.synchronize do
        check_not_closed?
        holdout_assignments.each_with_index do |holdout_assignment, i|
          next if holdout_assignment.nil? || holdout_assignment.exposed

          holdout_assignment.exposed = true
          (holdout_exposures ||= []) << enqueue_exposure(assignment.holdouts[i].name, holdout_assignment, exposed_at)
        end
      end
      holdout_exposures&.each { |e| log_event(ContextEventLogger::EVENT_TYPE::EXPOSURE, e) }
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
    # Ruby can't run the parse under the caller's mask inside a masked
    # cleanup, so an interrupt landing as the cleanup starts can skip it; a
    # registration only counts while the thread is inside build_state (see
    # building?), and the next build or wait drops one left behind.
    def build_state(data)
      thread = Thread.current
      nested = build_state_on_stack?(1)
      registered = false
      begin
        Thread.handle_interrupt(Object => :never) do
          @ready_mutex.synchronize do
            # [count, fiber that registered first]. A count left by an
            # interrupted cleanup in this fiber, with no build of it still
            # running further up the stack, is dropped first.
            entry = @building_threads[thread]
            # (The stack is checked above, before entering these blocks.)
            entry = nil if entry && (entry[1].equal?(Fiber.current) ? !nested : !entry[1].alive?)
            @building_threads[thread] = entry ? [entry[0] + 1, entry[1]] : [1, Fiber.current]
          end
          registered = true
        end
        build_state_maps(data)
      ensure
        if registered
          Thread.handle_interrupt(Object => :never) do
            @ready_mutex.synchronize do
              entry = @building_threads[thread]
              if entry && entry[0] > 1
                @building_threads[thread] = [entry[0] - 1, entry[1]]
              elsif entry
                @building_threads.delete(thread)
              end
            end
          end
        end
      end
    end

    # True while this thread is building a snapshot (a variable parser calling
    # back). A registration whose build has unwound without its cleanup is
    # dropped here, so the thread waits like any other.
    def building?
      thread = Thread.current
      entry = @ready_mutex.synchronize { @building_threads[thread] }
      return false if entry.nil?
      return true unless stale_build_entry?(entry)

      Thread.handle_interrupt(Object => :never) do
        @ready_mutex.synchronize { @building_threads.delete(thread) if @building_threads[thread].equal?(entry) }
      end
      false
    end

    # A backtrace covers only the current fiber, so the stack is checked only
    # from the fiber that registered; a parser that waits from a nested fiber
    # still counts as building. A registering fiber that has ended is stale.
    def stale_build_entry?(entry)
      fiber = entry[1]
      return !build_state_on_stack?(0) if fiber.equal?(Fiber.current)
      return true unless fiber.alive?
      # Ruby 3.0+ can read the registering fiber's stack from a fiber it
      # resumed; 2.7 cannot, so there a live registering fiber still counts.
      return false unless fiber.respond_to?(:backtrace_locations)

      !build_state_on_stack?(0, fiber.backtrace_locations || [])
    end

    # Whether more than skip build_state frames are on this thread's stack.
    # Called only outside build_state's blocks, so each frame is one build.
    def build_state_on_stack?(skip, locations = caller_locations)
      locations.count { |location| location.path == __FILE__ && location.base_label == "build_state" } > skip
    end

    def build_state_maps(data)
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

      State.new(data, index, index_variables, custom_fields)
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
      @holdout_assignments = nil
      @assignment_mutex = Mutex.new
      @failed_marked = false
      @exposing = {}.compare_by_identity
      @exposure_condvar = ConditionVariable.new
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
      @deferred_mutex = Mutex.new
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
    # Private: set by the context on an assignment built from a failed load's
    # empty snapshot. Initialized so every assignment keeps one layout.
    @failed_snapshot = false
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
