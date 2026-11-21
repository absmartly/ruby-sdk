# frozen_string_literal: true

require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_context_event_serializer"
require "default_variable_parser"
require "json/context_data"

RSpec.describe "Context assignment rules" do
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
      allow(context).to receive(:queue_exposure).and_wrap_original do |original, assignment, *rest|
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
      allow(context).to receive(:queue_exposure).and_wrap_original do |original, assignment, *rest|
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
        reader = Thread.new { context.send(:queue_exposure, assignment, "exp_test_abc") }
        expect(reader.join(0.2)).to be_nil
        resume << true
        Timeout.timeout(5) { setter.join }
        expect(Timeout.timeout(5) { reader.value }).to eq(:evicted)
      ensure
        resume << true
        setter.join(5) || setter.kill
        reader&.join(5) || reader&.kill
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
        locker&.join(5) || locker&.kill
        reader.join(5) || reader.kill
      end
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.instance_variable_get(:@exposing)).to be_empty
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
