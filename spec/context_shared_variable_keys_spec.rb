# frozen_string_literal: true

require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_variable_parser"
require "json/context_data"

# A variable key defined by several experiments, as java-sdk
# Context.getVariableAssignment resolves it: the candidates are walked in
# experiment id order, the first one the unit is assigned, overridden or
# rule-assigned in wins, and only that one is exposed. A winner whose variant
# lacks the key gives the caller default; the walk never moves on to a later
# candidate because of the arm the unit got.
module ContextSharedVariableKeysSpec
  RSpec.describe "Context shared variable keys" do
    UNIT_TYPE = "session_id"
    UID = "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
    # split [0.5, 0.5] with seeds 100/200 gives UID variant 1.
    VARIANT = 1
    # split [0.1, 0.9] with seeds 13/111 holds UID out (arm 0); 1/222 does not (arm 1).
    HOLDING_OUT = [13, 111].freeze
    NOT_HOLDING_OUT = [1, 222].freeze
    US_ONLY = '{"filter":[{"eq":[{"var":"country"},{"value":"US"}]}]}'
    US_RULE = JSON.generate(rules: [{ name: "US", type: "assign",
                                      conditions: { and: [{ eq: [{ var: "country" }, { value: "US" }] }] },
                                      environments: [], variant: 0 }])

    let(:clock) { Time.at(1620000000000 / 1000) }
    let(:published) { [] }
    let(:event_handler) do
      handler = double("ContextPublisher")
      allow(handler).to receive(:publish) do |_ctx, event|
        published << event
        OpenStruct.new(success?: true)
      end
      handler
    end
    let(:event_logger) do
      logger = double("ContextEventLogger")
      allow(logger).to receive(:handle_event)
      logger
    end

    # The key is defined in both variants unless configs are given.
    def experiment(id, name, configs: ['{"color":"control_%d"}', '{"color":"treatment_%d"}'], unit_type: UNIT_TYPE,
                   **extra)
      {
        id: id, name: name, unitType: unit_type, iteration: 1, seedHi: 100, seedLo: 200, split: [0.5, 0.5],
        trafficSeedHi: 1, trafficSeedLo: 2, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }], audienceStrict: false, audience: nil,
        variants: configs.each_with_index.map { |c, i| { name: ("A".ord + i).chr, config: c && format(c, id) } }
      }.merge(extra)
    end

    def strict_mismatch(id, name)
      experiment(id, name, audienceStrict: true, audience: US_ONLY)
    end

    def no_unit(id, name)
      experiment(id, name, unit_type: "user_id")
    end

    def holdout(id, name, seeds)
      {
        id: id, name: name, unitType: UNIT_TYPE, iteration: 1, seedHi: seeds[0], seedLo: seeds[1], split: [0.1, 0.9],
        trafficSeedHi: 0, trafficSeedLo: 0, trafficSplit: [0.0, 1.0], fullOnVariant: 0, applications: [],
        variants: [{ name: "A", config: nil }, { name: "B", config: nil }], audienceStrict: false, audience: nil,
        holdoutType: "full"
      }
    end

    def create_context(experiments, holdouts: nil, overrides: {}, country: "GB")
      payload = { experiments: experiments }
      payload[:holdouts] = holdouts unless holdouts.nil?
      json = JSON.generate(payload)
      data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
      config = ContextConfig.create
      config.set_units(UNIT_TYPE => UID)
      config.set_overrides(overrides)
      context = Context.create(clock, config, OpenStruct.new(data_future: data, success?: true),
                               double("ContextDataProvider"), event_handler, event_logger, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new),
                               application: "website", environment: "production")
      context.set_attribute("country", country)
      context
    end

    # [name, variant, assigned, overridden, rule_override]
    def exposures_of(context)
      context.publish
      published.flat_map { |event| event.exposures || [] }.map do |e|
        [e.name, e.variant, e.assigned, e.overridden, e.rule_override]
      end
    end

    def assigned(name, variant = VARIANT)
      [name, variant, true, false, false]
    end

    describe "a lower-id candidate the unit is not in" do
      it "reads from and exposes only the assigned higher-id candidate after a strict audience mismatch" do
        context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "reads from and exposes only the assigned higher-id candidate when its unit type is not set" do
        context = create_context([no_unit(1, "exp_low"), experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "orders the candidates by id, not payload order" do
        context = create_context([experiment(2, "exp_high"), strict_mismatch(1, "exp_low")])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_high")])
      end

      it "still exposes the loser through its own treatment call" do
        context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

        context.variable_value("color", "default")
        context.treatment("exp_low")
        expect(exposures_of(context)).to eq([assigned("exp_high"), ["exp_low", 0, false, false, false]])
      end
    end

    describe "a winner whose variant lacks the key" do
      it "returns the default and exposes only the winner, never a later candidate" do
        context = create_context([experiment(1, "exp_low", configs: ['{"color":"control_%d"}', '{"other":"x"}']),
                                  experiment(2, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("default")
        expect(context.pending_count).to eq(1)
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "returns the default when the winner's variant has no config at all" do
        context = create_context([experiment(1, "exp_low", configs: ['{"color":"control_%d"}', nil]),
                                  experiment(2, "exp_high")])

        expect(context.peek_variable_value("color", "default")).to eq("default")
        expect(context.variable_value("color", "default")).to eq("default")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end
    end

    it "returns the default and queues nothing when no candidate is assigned" do
      context = create_context([strict_mismatch(1, "exp_low"), no_unit(2, "exp_high")])

      expect(context.variable_value("color", "default")).to eq("default")
      expect(context.pending_count).to eq(0)
      expect(exposures_of(context)).to eq([])
    end

    it "returns the default and queues nothing for a key no experiment defines" do
      context = create_context([experiment(1, "exp_low")])

      expect(context.variable_value("missing", "default")).to eq("default")
      expect(context.pending_count).to eq(0)
    end

    it "queues nothing on peek and returns what variable_value returns" do
      context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

      expect(context.peek_variable_value("color", "default")).to eq("treatment_2")
      expect(context.pending_count).to eq(0)
      expect(context.variable_value("color", "default")).to eq("treatment_2")
      expect(context.pending_count).to eq(1)
    end

    it "queues the winner once across repeated reads" do
      context = create_context([strict_mismatch(1, "exp_low"), experiment(2, "exp_high")])

      3.times { context.variable_value("color", "default") }
      expect(exposures_of(context)).to eq([assigned("exp_high")])
    end

    # Each case puts a candidate the unit is not in first, so the walk visits a loser.
    describe "precedence" do
      it "lets an override on a candidate the unit is not in win" do
        context = create_context([strict_mismatch(1, "exp_skipped"), no_unit(2, "exp_low"), experiment(3, "exp_high")],
                                 overrides: { "exp_low" => 0 })

        expect(context.variable_value("color", "default")).to eq("control_2")
        expect(exposures_of(context)).to eq([["exp_low", 0, false, true, false]])
      end

      it "keeps an assigned lower-id candidate ahead of an override on a higher-id one" do
        context = create_context([strict_mismatch(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high")], overrides: { "exp_high" => 0 })

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "lets a rule on a strict-mismatch candidate win" do
        context = create_context([strict_mismatch(1, "exp_skipped"),
                                  strict_mismatch(2, "exp_low").merge(assignmentRules: US_RULE.sub("US\"}", "GB\"}")),
                                  experiment(3, "exp_high")])

        expect(context.variable_value("color", "default")).to eq("control_2")
        expect(exposures_of(context)).to eq([["exp_low", 0, false, false, true]])
      end

      it "keeps an assigned lower-id candidate ahead of a rule on a higher-id one" do
        context = create_context([no_unit(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high", assignmentRules: US_RULE)], country: "US")

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end
    end

    describe "values that are present but falsy" do
      [[nil, "null"], [false, "false"], [0, "0"], ["", '""'], [[], "[]"], [{}, "{}"]].each do |value, json|
        it "returns #{json} from the winner rather than the default" do
          context = create_context([strict_mismatch(1, "exp_low"),
                                    experiment(2, "exp_high", configs: ['{"color":1}', "{\"color\":#{json}}"])])

          expect(context.peek_variable_value("color", "default")).to eq(value)
          expect(context.variable_value("color", "default")).to eq(value)
          expect(exposures_of(context)).to eq([assigned("exp_high")])
        end
      end
    end

    # java-sdk fires the applicable holdouts of every candidate visited on a
    # non-peek read, while only the winner gets its own exposure.
    describe "holdouts" do
      it "exposes a visited loser's holdout but not the loser itself" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("exp_high")])
      end

      it "does not expose the holdouts of candidates after the winner" do
        context = create_context([no_unit(1, "exp_skipped"), experiment(2, "exp_low"),
                                  experiment(3, "exp_high", holdoutIds: [11])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_low")])
      end

      it "reads a held-out candidate's control only when no candidate is assigned" do
        context = create_context([experiment(1, "exp_low", holdoutIds: [11]), strict_mismatch(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("control_1")
        expect(exposures_of(context)).to eq([["holdout_a", 0, true, false, false]])
      end

      it "exposes a visited loser's holdout once across repeated reads" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        3.times { expect(context.variable_value("color", "default")).to eq("treatment_2") }
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("exp_high")])
      end

      it "exposes only a loser's still-unexposed holdout when another is already exposed" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11, 12]), experiment(2, "exp_high"),
                                  experiment(5, "exp_other", configs: ['{"size":1}', '{"size":2}'], holdoutIds: [11])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])
        context.treatment("exp_other")

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("exp_other"), assigned("holdout_a"), assigned("holdout_b"),
                                             assigned("exp_high")])
      end

      it "queues the winner's holdouts before the winner, as java-sdk does" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]),
                                  experiment(2, "exp_high", holdoutIds: [12])],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])

        expect(context.variable_value("color", "default")).to eq("treatment_2")
        expect(exposures_of(context)).to eq([assigned("holdout_a"), assigned("holdout_b"), assigned("exp_high")])
      end

      it "reads the clock only for the first exposures, not on warm reads past a covered loser" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])
        context.variable_value("color", "default")

        expect(clock).not_to receive(:to_i)
        3.times { context.variable_value("color", "default") }
      end

      it "queues no loser holdout exposure once a logger callback closed the context" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]),
                                  strict_mismatch(2, "exp_mid").merge(holdoutIds: [12]), experiment(3, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT),
                                            holdout(12, "holdout_b", NOT_HOLDING_OUT)])
        allow(event_logger).to receive(:handle_event) do |_type, data|
          context.close if data.is_a?(Exposure) && data.name == "holdout_a"
        end

        expect { context.variable_value("color", "default") }.to raise_error(IllegalStateException, /closed/)
        # close published what was queued before it; nothing was queued after.
        expect(published.flat_map(&:exposures).map(&:name)).to eq(["holdout_a"])
        expect(context.pending_count).to eq(0)
      end

      it "fires nothing on peek" do
        context = create_context([strict_mismatch(1, "exp_low").merge(holdoutIds: [11]), experiment(2, "exp_high")],
                                 holdouts: [holdout(11, "holdout_a", NOT_HOLDING_OUT)])

        expect(context.peek_variable_value("color", "default")).to eq("treatment_2")
        expect(context.pending_count).to eq(0)
      end
    end
  end
end
