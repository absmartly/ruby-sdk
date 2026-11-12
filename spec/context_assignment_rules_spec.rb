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
    handler = double("ContextPublisher")
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

    it "keeps an assign rule assignment when the unit is set" do
      context = create_context(context_data([assign_rule(1)]), units: {}, attributes: { country: "US" })
      expect(context.treatment("exp_test_abc")).to eq(1)

      context.set_unit("session_id", session_id)
      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(1)
    end
  end
end
