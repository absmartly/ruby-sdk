# frozen_string_literal: true

require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_context_event_serializer"
require "default_variable_parser"
require "json/context_data"
require "timeout"

RSpec.describe "Context assignment rules" do
  # Reads retry when an assignment is evicted before its exposure claim; a
  # regression that never stops retrying fails here instead of hanging CI.
  # Threads an example started are killed afterwards, so a timed-out example
  # can't leave one spinning and slow the rest of the suite.
  around do |example|
    before = Thread.list
    begin
      Timeout.timeout(10) { example.run }
    ensure
      (Thread.list - before).each(&:kill).each { |thread| thread.join(1) }
    end
  end

  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:session_id) { "e791e240fcd3df7d238cfc285f475e8152fcc0ec" }
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:published) { [] }
  let(:event_handler) do
    handler = double("Absmartly::ContextPublisher")
    allow(handler).to receive(:publish) do |_ctx, event|
      published << event
      publish_future
    end
    handler
  end
  let(:data_provider) { double("ContextDataProvider") }

  let(:us) { { and: [{ eq: [{ var: "country" }, { value: "US" }] }] } }

  def assign_rule(variant, conditions: us, environments: [])
    { name: "assign", type: "assign", conditions: conditions, environments: environments, variant: variant }
  end

  def split_rule(percentages, conditions: us, environments: [])
    { name: "split", type: "split", conditions: conditions, environments: environments, percentages: percentages }
  end

  # exp_test_abc gives this session variant 2 through normal assignment; the
  # unit hashes to ~0.748 with the experiment seed and ~0.682 with the traffic
  # seed, so a 70/10/20 split lands on 1 only when hashed with the experiment
  # seed.
  def context_data(rules, name: "exp_test_abc", **overrides)
    raw = JSON.parse(resource("context.json"), symbolize_names: true)
    raw[:experiments].each do |experiment|
      next unless experiment[:name] == name

      experiment[:assignmentRules] = rules.is_a?(String) ? rules : JSON.generate(rules: rules) unless rules.nil?
      experiment.merge!(overrides)
    end
    json = JSON.generate(raw)
    DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
  end

  def create_context(data, environment: "production", units: { session_id: session_id }, attributes: {})
    config = ContextConfig.create
    config.set_units(units)
    config.set_attributes(attributes)
    Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), data_provider,
                   event_handler, nil, variable_parser, audience_matcher,
                   application: "website", environment: environment)
  end

  def published_exposures(context)
    context.publish
    published.flat_map(&:exposures).compact
  end

  describe "assign rules" do
    it "assigns the rule variant when the conditions match" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "falls back to normal assignment when no rule matches" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "GB" })
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "flags the exposure ruleOverride, not assigned and eligible" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      context.treatment("exp_test_abc")

      exposure = published_exposures(context).find { |e| e.name == "exp_test_abc" }
      expect(exposure.variant).to eq(1)
      expect(exposure.rule_override).to eq(true)
      expect(exposure.assigned).to eq(false)
      expect(exposure.eligible).to eq(true)
      expect(exposure.overridden).to eq(false)
      expect(exposure.custom).to eq(false)
      expect(exposure.full_on).to eq(false)
      expect(exposure.audience_mismatch).to eq(false)
    end

    it "serializes ruleOverride for every exposure" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      context.treatment("exp_test_abc")
      context.treatment("exp_test_ab")
      context.publish

      body = JSON.parse(DefaultContextEventSerializer.new.serialize(published.first))
      flags = body["exposures"].to_h { |e| [e["name"], e["ruleOverride"]] }
      expect(flags).to eq("exp_test_abc" => true, "exp_test_ab" => false)
    end

    it "wins over a custom assignment and exposes only once" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      context.set_custom_assignment("exp_test_abc", 0)
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(1)

      context.set_attribute("country", "GB")
      expect(context.treatment("exp_test_abc")).to eq(0)
    end

    it "loses to an override" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      context.set_override("exp_test_abc", 0)
      expect(context.treatment("exp_test_abc")).to eq(0)

      exposure = published_exposures(context).first
      expect(exposure.overridden).to eq(true)
      expect(exposure.rule_override).to eq(false)
    end

    it "wins over a strict audience mismatch" do
      data = context_data([assign_rule(1)], audienceStrict: true,
                                            audience: JSON.generate(filter: [{ gte: [{ var: "age" }, { value: 20 }] }]))
      context = create_context(data, attributes: { country: "US", age: 10 })
      expect(context.treatment("exp_test_abc")).to eq(1)

      exposure = published_exposures(context).first
      expect(exposure.audience_mismatch).to eq(false)
      expect(exposure.rule_override).to eq(true)
    end

    it "wins over a full-on variant" do
      context = create_context(context_data([assign_rule(1)], name: "exp_test_fullon"), attributes: { country: "US" })
      expect(context.treatment("exp_test_fullon")).to eq(1)
    end

    it "wins over traffic ineligibility" do
      data = context_data([assign_rule(1)], name: "exp_test_not_eligible")
      context = create_context(data, units: { session_id: session_id, user_id: "123456789" },
                                     attributes: { country: "US" })
      expect(context.treatment("exp_test_not_eligible")).to eq(1)
    end

    it "does not need the unit" do
      context = create_context(context_data([assign_rule(1)]), units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "falls back to normal assignment, without trying later rules, for an out-of-range variant" do
      context = create_context(context_data([assign_rule(3), assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "takes the first matching rule" do
      rules = [assign_rule(0, conditions: { eq: [{ var: "country" }, { value: "GB" }] }), assign_rule(1), assign_rule(0)]
      context = create_context(context_data(rules), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "only applies environment-scoped rules in those environments" do
      rules = [assign_rule(1, environments: ["production"])]
      expect(create_context(context_data(rules), attributes: { country: "US" }).treatment("exp_test_abc")).to eq(1)
      expect(create_context(context_data(rules), environment: "staging",
                                                 attributes: { country: "US" }).treatment("exp_test_abc")).to eq(2)
      expect(create_context(context_data(rules), environment: nil,
                                                 attributes: { country: "US" }).treatment("exp_test_abc")).to eq(2)
    end

    it "evaluates conditions against the application and environment" do
      rules = [assign_rule(1, conditions: { eq: [{ var: "environment" }, { value: "production" }] })]
      expect(create_context(context_data(rules)).treatment("exp_test_abc")).to eq(1)
      expect(create_context(context_data(rules), environment: "staging").treatment("exp_test_abc")).to eq(2)
    end

    it "ignores rules that are not valid JSON" do
      context = create_context(context_data("not json"), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "re-evaluates the rule when an attribute changes" do
      context = create_context(context_data([assign_rule(1)]))
      expect(context.treatment("exp_test_abc")).to eq(2)

      context.set_attribute("country", "US")
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(2)
    end

    it "keeps the cached assignment when an unrelated attribute changes" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      context.set_attribute("age", 30)
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "exposes variables for the rule variant" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.variable_value("button.color", "red")).to eq("blue")
    end

    it "re-resolves rule assignments after a refresh changes the rules" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      allow(data_provider).to receive(:context_data)
        .and_return(OpenStruct.new(data_future: context_data(nil), success?: true))
      context.refresh
      expect(context.treatment("exp_test_abc")).to eq(2)
    end
    it "applies rules a refresh adds to a rule-free, audience-free experiment" do
      context = create_context(context_data(nil), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)

      allow(data_provider).to receive(:context_data)
        .and_return(OpenStruct.new(data_future: context_data([assign_rule(1)]), success?: true))
      context.refresh
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    # Pins current behaviour: the cached read of an audience-free experiment
    # does not record the attribute change, so an audience a later refresh
    # adds is evaluated against it. JS 1.13.4 also gives 0; javascript-sdk
    # main (311cfca, unreleased) keeps the variant.
    it "evaluates an audience a refresh adds against attributes set since the last read" do
      context = create_context(context_data(nil), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)
      context.set_attribute("age", 10)
      expect(context.treatment("exp_test_abc")).to eq(2)

      strict = context_data(nil, audienceStrict: true,
                                 audience: JSON.generate(filter: [{ gte: [{ var: "age" }, { value: 20 }] }]))
      allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: strict, success?: true))
      context.refresh
      expect(context.treatment("exp_test_abc")).to eq(0)
    end

    it "drops a rule-won assignment once a refresh removes the experiment" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      data = context_data(nil)
      data.experiments.reject! { |e| e.name == "exp_test_abc" }
      allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
      context.refresh
      expect(context.treatment("exp_test_abc")).to eq(0)
    end
  end

  describe "split rules" do
    it "hashes the unit with the experiment seed" do
      context = create_context(context_data([split_rule("70/10/20")]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "assigns the only variant with a non-zero share" do
      context = create_context(context_data([split_rule("0/100/0")]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "keeps the normal variant when the split equals the experiment split" do
      context = create_context(context_data([split_rule("34/33/33")]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "sets the same exposure flags as an assign rule" do
      context = create_context(context_data([split_rule("0/100/0")]), attributes: { country: "US" })
      context.treatment("exp_test_abc")

      exposure = published_exposures(context).first
      expect([exposure.variant, exposure.rule_override, exposure.assigned, exposure.eligible]).to eq([1, true, false, true])
    end

    it "skips a split that does not sum to 100 in favour of the next rule" do
      context = create_context(context_data([split_rule("50/50/50"), assign_rule(0)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(0)
    end

    it "falls back to normal assignment for a split without one percentage per variant" do
      context = create_context(context_data([split_rule("50/50"), assign_rule(0)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "gives variant 0 without the unit, then re-resolves once the unit is set" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      expect(context.peek_treatment("exp_test_abc")).to eq(0)

      context.set_unit("session_id", session_id)
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "gives the full-on variant without the unit" do
      context = create_context(context_data([split_rule("100/0/0/0")], name: "exp_test_fullon"),
                               units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_fullon")).to eq(2)
    end

    it "gives variant 0 without the unit when the experiment has no fullOnVariant" do
      raw = JSON.parse(resource("context.json"))
      raw["experiments"].each do |experiment|
        next unless experiment["name"] == "exp_test_abc"

        experiment.delete("fullOnVariant")
        experiment["assignmentRules"] = JSON.generate(rules: [split_rule("0/100/0")])
      end
      json = JSON.generate(raw)
      data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)

      context = create_context(data, units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(0)
    end

    it "keeps an exposed no-unit split on its variant after the unit is set" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(0)

      context.set_unit("session_id", session_id)
      expect(context.treatment("exp_test_abc")).to eq(0)
      context.set_attribute("age", 30)
      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(context.pending_count).to eq(1)
    end

    def clocked_context(data, clock_object, units: {}, attributes: {})
      config = ContextConfig.create
      config.set_units(units)
      config.set_attributes(attributes)
      Context.create(clock_object, config, OpenStruct.new(data_future: data, success?: true), data_provider,
                     event_handler, nil, variable_parser, audience_matcher,
                     application: "website", environment: "production")
    end

    it "keeps the no-unit variant when the unit is set during that exposure's clock" do
      holder = {}
      sid = session_id
      clock_object = Object.new
      clock_object.define_singleton_method(:to_i) do
        if holder[:arm]
          holder[:arm] = false
          holder[:context].set_unit("session_id", sid)
        end
        123
      end
      context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
      holder[:context] = context
      holder[:arm] = true

      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
    end

    it "rebuilds the no-unit variant if its exposure fails after the unit was set during the clock" do
      holder = {}
      sid = session_id
      clock_object = Object.new
      clock_object.define_singleton_method(:to_i) do
        if holder[:arm]
          holder[:arm] = false
          holder[:context].set_unit("session_id", sid)
          raise "clock failed"
        end
        123
      end
      context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
      holder[:context] = context
      holder[:arm] = true

      expect { context.treatment("exp_test_abc") }.to raise_error("clock failed")
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 1]])
    end

    it "re-resolves a no-unit assignment evicted by set_unit between its lookup and exposure" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      sid = session_id
      armed = true
      allow(context).to receive(:claim_and_queue_exposure).and_wrap_original do |original, assignment, *rest|
        if armed
          armed = false
          context.set_unit("session_id", sid)
        end
        original.call(assignment, *rest)
      end

      first = context.treatment("exp_test_abc")
      expect(context.treatment("exp_test_abc")).to eq(first)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", first]])
    end

    it "re-resolves a variable read whose assignment set_unit evicted before its exposure" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      sid = session_id
      armed = true
      allow(context).to receive(:claim_and_queue_exposure).and_wrap_original do |original, assignment, *rest|
        if armed
          armed = false
          context.set_unit("session_id", sid)
        end
        original.call(assignment, *rest)
      end

      first = context.variable_value("button.color", "default")
      expect(context.variable_value("button.color", "default")).to eq(first)
      variants = published_exposures(context).map { |e| [e.name, e.variant] }
      expect(variants.map(&:first)).to eq(["exp_test_abc"])
    end

    # The refresh and set_unit land right after the lookup returns, before
    # the caller decides which assignment its exposure claim must match.
    %i[treatment variable_value].each do |read|
      it "re-resolves a #{read} when a refresh and set_unit land right after its lookup" do
        data = context_data([split_rule("0/100/0")])
        allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
        context = create_context(data, units: {}, attributes: { country: "US" })
        sid = session_id
        armed = true
        allow(context).to receive(:assignment).and_wrap_original do |original, *args|
          result = original.call(*args)
          if armed
            armed = false
            context.refresh
            context.set_unit("session_id", sid)
          end
          result
        end
        call = read == :treatment ? -> { context.treatment("exp_test_abc") } : -> { context.variable_value("button.color", "d") }

        first = call.call
        expect(call.call).to eq(first)
        expect(published_exposures(context).map(&:name)).to eq(["exp_test_abc"])
      end
    end

    it "does not claim an exposure that set_unit is evicting" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      sid = session_id
      assignment = context.send(:assignment, "exp_test_abc")
      cache = context.instance_variable_get(:@assignment_cache)
      in_eviction = Queue.new
      resume = Queue.new
      # Park set_unit inside its eviction, holding the assignment lock, after
      # it has read which exposures are in progress.
      allow(cache).to receive(:delete_if).and_wrap_original do |original, &block|
        if Thread.current[:gate]
          Thread.current[:gate] = false
          in_eviction << true
          resume.pop
        end
        original.call(&block)
      end
      setter = Thread.new do
        Thread.current[:gate] = true
        context.set_unit("session_id", sid)
      end
      reader = nil
      begin
        Timeout.timeout(5) { in_eviction.pop }
        reader = Thread.new { context.send(:claim_and_queue_exposure, assignment, "exp_test_abc") }
        expect(reader.join(0.2)).to be_nil
        resume << true
        Timeout.timeout(5) { setter.join }
        expect(Timeout.timeout(5) { reader.value }).to eq(:evicted)
      ensure
        resume << true
        setter.join(1) || setter.kill
        reader&.join(1) || reader&.kill
      end

      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 1]])
    end

    it "lets a timeout interrupt an exposure's cleanup waiting for the assignment lock" do
      holder = {}
      sid = session_id
      in_clock = Queue.new
      clock_object = Object.new
      clock_object.define_singleton_method(:to_i) do
        if holder[:arm]
          holder[:arm] = false
          holder[:context].set_unit("session_id", sid)
          in_clock << true
          sleep
        end
        123
      end
      context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
      holder[:context] = context
      lock = context.instance_variable_get(:@assignment_mutex)
      locked = Queue.new
      release = Queue.new
      reader = Thread.new do
        holder[:arm] = true
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        begin
          Timeout.timeout(0.3) { context.treatment("exp_test_abc") }
        rescue Timeout::Error
          nil
        end
        Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      end
      locker = nil
      begin
        Timeout.timeout(5) { in_clock.pop }
        # Held when the timeout unwinds the clock, so cleanup must wait for it.
        locker = Thread.new { lock.synchronize { locked << true; Timeout.timeout(1.5) { release.pop } rescue nil } }
        Timeout.timeout(5) { locked.pop }
        expect(Timeout.timeout(5) { reader.value }).to be < 1
      ensure
        release << true
        locker&.join(1) || locker&.kill
        reader.join(1) || reader.kill
      end
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.instance_variable_get(:@exposing)).to be_empty
    end

    def unit_setting_clock(holder, sid, raise_after: false)
      clock_object = Object.new
      clock_object.define_singleton_method(:to_i) do
        if Thread.current[:arm]
          Thread.current[:arm] = false
          holder[:context].set_unit("session_id", sid)
          holder[:in_clock] << true
          holder[:resume].pop
          raise "clock failed" if raise_after
        end
        123
      end
      clock_object
    end

    %i[treatment variable_value].each do |read|
      it "a #{read} waiting on a failed no-unit exposure resolves the unit set during it" do
        holder = { in_clock: Queue.new, resume: Queue.new }
        clock_object = unit_setting_clock(holder, session_id, raise_after: true)
        context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
        holder[:context] = context
        call = read == :treatment ? -> { context.treatment("exp_test_abc") } : -> { context.variable_value("button.color", "d") }
        owner = Thread.new do
          Thread.current[:arm] = true
          call.call
        rescue RuntimeError
          nil
        end
        waiter = nil
        begin
          Timeout.timeout(5) { holder[:in_clock].pop }
          waiter = Thread.new { call.call }
          expect(waiter.join(0.1)).to be_nil
          holder[:resume] << true
          Timeout.timeout(5) { owner.join }
          expected = read == :treatment ? 1 : "blue"
          expect(Timeout.timeout(5) { waiter.value }).to eq(expected)
        ensure
          holder[:resume] << true
          owner.join(1) || owner.kill
          waiter&.join(1) || waiter&.kill
        end
        expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 1]])
      end
    end

    it "a concurrent read during a no-unit exposure that sets the unit serves the variant being exposed" do
      holder = { in_clock: Queue.new, resume: Queue.new }
      clock_object = unit_setting_clock(holder, session_id)
      context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
      holder[:context] = context
      owner = Thread.new do
        Thread.current[:arm] = true
        context.treatment("exp_test_abc")
      end
      begin
        Timeout.timeout(5) { holder[:in_clock].pop }
        expect(context.peek_treatment("exp_test_abc")).to eq(0)
        holder[:resume] << true
        expect(Timeout.timeout(5) { owner.value }).to eq(0)
      ensure
        holder[:resume] << true
        owner.join(1) || owner.kill
      end
      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
    end

    it "reuses a no-unit split assignment while its unit is still missing" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      context.peek_treatment("exp_test_abc")
      matcher = context.send(:rule_matcher)
      allow(matcher).to receive(:evaluate_parsed_rules).and_call_original
      3.times { context.peek_treatment("exp_test_abc") }
      expect(matcher).not_to have_received(:evaluate_parsed_rules)
    end

    # Another read rebuilds the cached entry right after this read's lookup;
    # the exposure claim must then resolve again rather than expose the old one.
    %i[treatment variable_value].each do |read|
      it "re-resolves a #{read} whose cached assignment another read rebuilt after its lookup" do
        context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
        armed = true
        allow(context).to receive(:assignment).and_wrap_original do |original, *args|
          result = original.call(*args)
          if armed
            armed = false
            context.set_override("exp_test_abc", 0)
            context.peek_treatment("exp_test_abc")
          end
          result
        end
        call = read == :treatment ? -> { context.treatment("exp_test_abc") } : -> { context.variable_value("button.color", "d") }
        expected = read == :treatment ? 0 : "d"

        expect(call.call).to eq(expected)
        expect(call.call).to eq(expected)
        expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
      end
    end

    it "takes no exposure claim or stale check on a warm read of an exposed experiment" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      context.treatment("exp_test_abc")
      context.variable_value("button.color", "d")
      allow(context).to receive(:claim_and_queue_exposure).and_call_original
      allow(context).to receive(:stale_missing_unit?).and_call_original

      context.variable_value("button.color", "d")
      context.peek_treatment("exp_test_abc")

      expect(context).not_to have_received(:claim_and_queue_exposure)
      expect(context).not_to have_received(:stale_missing_unit?)
    end

    it "keeps the no-unit variant when its clock sets the unit and an attribute, then reads" do
      holder = {}
      sid = session_id
      clock_object = Object.new
      clock_object.define_singleton_method(:to_i) do
        if holder[:arm]
          holder[:arm] = false
          holder[:context].set_unit("session_id", sid)
          holder[:context].set_attribute("age", 30)
          holder[:peeked] = holder[:context].peek_treatment("exp_test_abc")
        end
        123
      end
      context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
      holder[:context] = context
      holder[:arm] = true

      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(holder[:peeked]).to eq(0)
      expect(context.treatment("exp_test_abc")).to eq(0)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
    end

    %i[evicted logged].each do |returned|
      it "serves and exposes the same when the exposure logger returns #{returned.inspect}" do
        holder = { calls: 0 }
        logger = Class.new(ContextEventLogger) do
          define_method(:handle_event) do |event, _data|
            next unless event == ContextEventLogger::EVENT_TYPE::EXPOSURE

            holder[:calls] += 1
            next unless holder[:calls] == 1

            holder[:context].set_override("exp_test_abc", 0)
            returned
          end
        end.new
        config = ContextConfig.create
        config.set_units(session_id: session_id)
        config.set_attributes(country: "US")
        context = Context.create(clock, config, OpenStruct.new(data_future: context_data(nil), success?: true),
                                 data_provider, event_handler, logger, variable_parser, audience_matcher,
                                 application: "website", environment: "production")
        holder[:context] = context

        expect(context.variable_value("button.color", "default")).to eq("red")
        expect(context.treatment("exp_test_abc")).to eq(0)
        expect(published_exposures(context).map { |e| [e.name, e.variant] })
          .to eq([["exp_test_abc", 2], ["exp_test_abc", 0]])
      end
    end

    %i[evicted logged].each do |returned|
      it "a first treatment serves and exposes the same when the exposure logger returns #{returned.inspect}" do
        holder = { calls: 0 }
        logger = Class.new(ContextEventLogger) do
          define_method(:handle_event) do |event, _data|
            next unless event == ContextEventLogger::EVENT_TYPE::EXPOSURE

            holder[:calls] += 1
            next unless holder[:calls] == 1

            holder[:context].set_override("exp_test_abc", 0)
            returned
          end
        end.new
        config = ContextConfig.create
        config.set_units(session_id: session_id)
        config.set_attributes(country: "US")
        context = Context.create(clock, config, OpenStruct.new(data_future: context_data(nil), success?: true),
                                 data_provider, event_handler, logger, variable_parser, audience_matcher,
                                 application: "website", environment: "production")
        holder[:context] = context

        expect(context.treatment("exp_test_abc")).to eq(2)
        expect(context.treatment("exp_test_abc")).to eq(0)
        expect(published_exposures(context).map { |e| [e.name, e.variant] })
          .to eq([["exp_test_abc", 2], ["exp_test_abc", 0]])
      end
    end

    it "the public queue_exposure queues any assignment it is given, as in 1.3.0" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      no_unit = context.send(:assignment, "exp_test_abc")
      context.set_unit("session_id", session_id)

      context.queue_exposure(no_unit)
      expect(context.pending_count).to eq(1)
      expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
    end

    # A concurrent read checks an assignment just as its exposure completes:
    # it must not see it as neither exposed nor being exposed.
    [[false, 1], [true, 1], [true, 2]].each do |with_attribute, gate_at|
      it "keeps the no-unit variant when a read overlaps its exposure completing#{" after an attribute update" if with_attribute} at check #{gate_at}" do
        holder = { in_clock: Queue.new, resume: Queue.new }
        sid = session_id
        clock_object = Object.new
        clock_object.define_singleton_method(:to_i) do
          if Thread.current[:arm]
            Thread.current[:arm] = false
            holder[:context].set_unit("session_id", sid)
            holder[:context].set_attribute("age", 30) if with_attribute
            holder[:in_clock] << true
            holder[:resume].pop
          end
          123
        end
        context = clocked_context(context_data([split_rule("0/100/0")]), clock_object, attributes: { country: "US" })
        holder[:context] = context
        queue_mutex = context.instance_variable_get(:@queue_mutex)
        checking = Queue.new
        proceed = Queue.new
        # Park the reader as it takes the queue lock to check the assignment's
        # exposure state, until the owner has completed its exposure.
        allow(queue_mutex).to receive(:synchronize).and_wrap_original do |original, &block|
          if Thread.current[:gate]
            Thread.current[:checks] = (Thread.current[:checks] || 0) + 1
            if Thread.current[:checks] == gate_at
              Thread.current[:gate] = false
              checking << true
              proceed.pop
            end
          end
          original.call(&block)
        end
        owner = Thread.new do
          Thread.current[:arm] = true
          context.treatment("exp_test_abc")
        end
        reader = nil
        begin
          Timeout.timeout(5) { holder[:in_clock].pop }
          reader = Thread.new do
            Thread.current[:gate] = true
            context.peek_treatment("exp_test_abc")
          end
          Timeout.timeout(5) { checking.pop }
          holder[:resume] << true
          expect(Timeout.timeout(5) { owner.value }).to eq(0)
          proceed << true
          expect(Timeout.timeout(5) { reader.value }).to eq(0)
        ensure
          holder[:resume] << true
          proceed << true
          owner.join(1) || owner.kill
          reader&.join(1) || reader&.kill
        end
        expect(context.treatment("exp_test_abc")).to eq(0)
        expect(published_exposures(context).map { |e| [e.name, e.variant] }).to eq([["exp_test_abc", 0]])
      end
    end

    it "does not take the queue lock to check a no-unit assignment already exposed" do
      context = create_context(context_data([split_rule("0/100/0")]), units: {}, attributes: { country: "US" })
      context.treatment("exp_test_abc")
      context.set_unit("session_id", session_id)
      context.set_attribute("age", 30)
      assignment = context.send(:assignment, "exp_test_abc")
      mutex = context.instance_variable_get(:@queue_mutex)
      expect(mutex).not_to receive(:synchronize)
      expect(context.send(:exposed_or_exposing?, assignment)).to be true
    end

    it "does not reinstall an old variable assignment after refresh exposes the new one" do
      old_data = context_data([assign_rule(2)])
      new_data = context_data([assign_rule(1)])
      allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: new_data, success?: true))
      context = create_context(old_data, attributes: { country: "US" })
      armed = true
      allow(context).to receive(:assignment).and_wrap_original do |original, *args|
        result = original.call(*args)
        if armed
          armed = false
          context.refresh
          expect(context.variable_value("button.color", "d")).to eq("blue")
        end
        result
      end
      context.variable_value("button.color", "d")
      expect(context.variable_value("button.color", "d")).to eq("blue")
      variants = published_exposures(context).select { |e| e.name == "exp_test_abc" }.map(&:variant)
      expect(variants.count(1)).to eq(1)
    end

    it "uses the latest String or Symbol spelling of an attribute in the built-in evaluator" do
      staging = { and: [{ eq: [{ var: "environment" }, { value: "staging" }] }] }
      context = create_context(context_data([assign_rule(1, conditions: staging)]))
      context.set_attribute("environment", "prod")
      expect(context.treatment("exp_test_abc")).to eq(2)

      context.set_attribute(:environment, "staging")
      expect(context.treatment("exp_test_abc")).to eq(1)

      context.set_attribute("environment", "prod")
      expect(context.treatment("exp_test_abc")).to eq(2)
    end

    it "keeps an assign rule assignment when the unit is set" do
      context = create_context(context_data([assign_rule(1)]), units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      context.set_unit("session_id", session_id)
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(1)
    end
  end

  # A matcher written against the v1.3.0 contract: only evaluate(audience, attrs).
  class LegacyAudienceMatcher
    attr_reader :calls

    def initialize
      @inner = AudienceMatcher.new(DefaultAudienceDeserializer.new)
      @calls = 0
    end

    def evaluate(audience, attributes)
      @calls += 1
      @inner.evaluate(audience, attributes)
    end
  end

  describe "custom audience matchers" do
    def create_with(matcher, data, attributes: {})
      config = ContextConfig.create
      config.set_units(session_id: session_id)
      config.set_attributes(attributes)
      Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), data_provider,
                     event_handler, nil, variable_parser, matcher,
                     application: "website", environment: "production")
    end

    it "works with a matcher that only implements evaluate when there are no rules" do
      matcher = LegacyAudienceMatcher.new
      context = create_with(matcher, context_data(nil))

      expect(context.ready?).to eq(true)
      expect(context.treatment("exp_test_abc")).to eq(2)
      expect(context.treatment("exp_test_ab")).to eq(1)
    end

    it "still dispatches audiences to the custom matcher" do
      matcher = LegacyAudienceMatcher.new
      audience = JSON.generate(filter: [{ eq: [{ var: "country" }, { value: "US" }] }])
      data = context_data(nil, name: "exp_test_ab", audience: audience, audienceStrict: true)
      context = create_with(matcher, data, attributes: { country: "GB" })
      expect(context.treatment("exp_test_ab")).to eq(0)
      expect(matcher.calls).to eq(1)
    end

    it "evaluates rules with the default rule engine when the matcher lacks it" do
      matcher = LegacyAudienceMatcher.new
      context = create_with(matcher, context_data([assign_rule(1)]), attributes: { country: "US" })

      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(published_exposures(context).first.rule_override).to eq(true)
    end
  end

  describe "cached reads" do
    it "parses rules once at install, not on resolution or attribute revalidation" do
      parses = 0
      allow(audience_matcher).to receive(:parse_rules).and_wrap_original do |original, *args|
        parses += 1
        original.call(*args)
      end
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(parses).to eq(1)
      expect(context.treatment("exp_test_abc")).to eq(1)
      3.times do |i|
        context.set_attribute("unrelated", i)
        expect(context.peek_treatment("exp_test_abc")).to eq(1)
      end
      expect(parses).to eq(1)
    end

    def count_rule_evaluations
      calls = 0
      allow(audience_matcher).to receive(:evaluate_parsed_rules).and_wrap_original do |original, *args|
        calls += 1
        original.call(*args)
      end
      -> { calls }
    end

    it "does not re-resolve the rule on every read after a same-outcome refresh" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      calls = count_rule_evaluations
      allow(data_provider).to receive(:context_data)
        .and_return(OpenStruct.new(data_future: context_data([assign_rule(1), assign_rule(0)]), success?: true))
      context.refresh

      100.times { expect(context.treatment("exp_test_abc")).to eq(1) }
      expect(calls.call).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "compares refreshed rules by identity once their text is acknowledged" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      refreshed = context_data([assign_rule(1)])
      rules = refreshed.experiments.find { |e| e.name == "exp_test_abc" }.assignment_rules
      comparisons = 0
      rules.define_singleton_method(:==) do |other|
        comparisons += 1
        super(other)
      end
      allow(data_provider).to receive(:context_data)
        .and_return(OpenStruct.new(data_future: refreshed, success?: true))
      context.refresh

      100.times { expect(context.treatment("exp_test_abc")).to eq(1) }
      expect(comparisons).to eq(1)
    end

    it "does not re-resolve the rule on every read after an attribute change" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      calls = count_rule_evaluations
      context.set_attribute("age", 30)
      100.times { expect(context.treatment("exp_test_abc")).to eq(1) }
      expect(calls.call).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "does not re-evaluate the audience on every read after an attribute change" do
      audience = JSON.generate(filter: [{ value: true }])
      context = create_context(context_data(nil, name: "exp_test_ab", audience: audience))
      expect(context.treatment("exp_test_ab")).to eq(1)

      calls = 0
      allow(audience_matcher).to receive(:evaluate).and_wrap_original do |original, *args|
        calls += 1
        original.call(*args)
      end
      context.set_attribute("age", 30)
      100.times { expect(context.treatment("exp_test_ab")).to eq(1) }
      expect(calls).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "rebuilds a rule-won assignment once a refresh removes the rules, even with no audience" do
      context = create_context(context_data([assign_rule(1)]), attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      allow(data_provider).to receive(:context_data)
        .and_return(OpenStruct.new(data_future: context_data(nil, audience: nil), success?: true))
      context.refresh
      expect(context.treatment("exp_test_abc")).to eq(2)
      expect(context.treatment("exp_test_abc")).to eq(2)
      expect(context.pending_count).to eq(2)
    end

    it "does not copy the rules on a cached read" do
      rules = [assign_rule(1, conditions: { value: true })] + Array.new(50) { assign_rule(0) }
      context = create_context(context_data(rules), attributes: { country: "US" })
      context.peek_treatment("exp_test_abc")

      before = GC.stat(:total_allocated_objects)
      1000.times { context.peek_treatment("exp_test_abc") }
      expect(GC.stat(:total_allocated_objects) - before).to be < 100
    end
  end

  describe "environment scope" do
    it "scopes rules to the configured environment, not an environment attribute" do
      staging = [assign_rule(1, conditions: nil, environments: ["staging"])]
      context = create_context(context_data(staging), attributes: { environment: "staging" })
      expect(context.treatment("exp_test_abc")).to eq(2)

      production = [assign_rule(1, conditions: nil, environments: ["production"])]
      context = create_context(context_data(production), attributes: { environment: "staging" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "lets an environment attribute override the system value in conditions" do
      condition = { eq: [{ var: "environment" }, { value: "staging" }] }
      context = create_context(context_data([assign_rule(1, conditions: condition)]),
                               attributes: { environment: "staging" })
      expect(context.treatment("exp_test_abc")).to eq(1)
    end

    it "does not inject any app_version into rule conditions" do
      absent = { null: { var: "app_version" } }
      context = create_context(context_data([assign_rule(1, conditions: absent)]))
      expect(context.treatment("exp_test_abc")).to eq(1)
    end
  end
end
