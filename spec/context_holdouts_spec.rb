# frozen_string_literal: true

require "context"
require "context_config"
require "audience_matcher"
require "default_audience_deserializer"
require "default_context_data_deserializer"
require "default_context_event_serializer"
require "default_variable_parser"
require "hashing"
require "json/context_data"

# Port of java-sdk ContextHoldoutTest (core-api/src/test/java/com/absmartly/sdk/ContextHoldoutTest.java),
# with javascript-sdk src/context.ts as the reference where the two differ.
# A holdout arrives in ContextData.holdouts; an experiment opts in through
# holdoutIds. Arm 0 holds the unit out; in a 3-arm holdout arm 1 also holds out
# experiments that are not full-on. A held-out unit gets control and no
# exposure for the covered experiment; the holdout exposes once per unit type.
module ContextHoldoutsSpec
  RSpec.describe "Context holdouts" do
    UNIT_TYPE = "session_id"
    UID = "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
    UID_NOT_HELD_OUT = "b2c3d4e5f6a1b2c3d4e5f6a1b2c3d4e5f6a1b2c3"

    # split [0.5, 0.5] with seeds 100/200: variant 1 for UID, 0 for UID_NOT_HELD_OUT.
    NORMAL_VARIANT = 1
    # split [0.1, 0.9] with seeds 13/111: arm 0 (held out) for UID, arm 1 for UID_NOT_HELD_OUT.
    HOLDOUT_A = [13, 111].freeze
    # split [0.1, 0.9] with seeds 1/222: arm 1 (not held out) for both UIDs.
    HOLDOUT_B = [1, 222].freeze
    # split [0.3, 0.3, 0.4] for UID: seedLo 1 -> arm 0, 3 -> arm 1, 0 -> arm 2.
    THREE_ARM_SPLIT = [0.3, 0.3, 0.4].freeze
    THREE_ARM_0 = [0, 1].freeze
    THREE_ARM_1 = [0, 3].freeze
    THREE_ARM_2 = [0, 0].freeze

    US_RULE = JSON.generate(rules: [{ name: "US Internal Users", type: "assign",
                                      conditions: { and: [{ eq: [{ var: "country" }, { value: "US" }] }] },
                                      environments: [], variant: 1 }])

    let(:clock) { Time.at(1620000000000 / 1000) }
    let(:now) { clock.to_i * 1000 }
    let(:variable_parser) { DefaultVariableParser.new }
    let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
    let(:published) { [] }
    let(:event_handler) do
      handler = double("ContextPublisher")
      allow(handler).to receive(:publish) do |_ctx, event|
        published << event
        OpenStruct.new(success?: true)
      end
      handler
    end
    let(:data_provider) { double("ContextDataProvider") }
    let(:logged) { [] }
    let(:event_logger) do
      logger = double("ContextEventLogger")
      allow(logger).to receive(:handle_event) { |type, data| logged << [type, data] }
      logger
    end

    def experiment(id, name, unit_type: UNIT_TYPE, full_on_variant: 0, holdout_ids: nil, **extra)
      hash = {
        id: id, name: name, unitType: unit_type, iteration: 1, seedHi: 100, seedLo: 200, split: [0.5, 0.5],
        trafficSeedHi: 1, trafficSeedLo: 2, trafficSplit: [0.0, 1.0], fullOnVariant: full_on_variant,
        applications: [{ name: "website" }], variants: [{ name: "A", config: nil }, { name: "B", config: nil }],
        audienceStrict: false, audience: nil
      }
      hash[:holdoutIds] = holdout_ids unless holdout_ids.nil?
      hash.merge(extra)
    end

    def holdout(id, name, seeds, unit_type: UNIT_TYPE, holdout_type: "full", split: [0.1, 0.9], **extra)
      {
        id: id, name: name, unitType: unit_type, iteration: 1, seedHi: seeds[0], seedLo: seeds[1], split: split,
        trafficSeedHi: 0, trafficSeedLo: 0, trafficSplit: [0.0, 1.0], fullOnVariant: 0, applications: [],
        variants: split.each_index.map { |i| { name: ("A".ord + i).chr, config: nil } },
        audienceStrict: false, audience: nil, holdoutType: holdout_type
      }.merge(extra)
    end

    def three_arm_holdout(id, name, seeds)
      holdout(id, name, seeds, holdout_type: "all_full_on", split: THREE_ARM_SPLIT)
    end

    def with_variables(experiment, key)
      experiment.merge(variants: [{ name: "A", config: "{\"#{key}\":\"control\"}" },
                                  { name: "B", config: "{\"#{key}\":\"treatment\"}" }])
    end

    # Decodes through the SDK's own deserializer, as a fetched payload is.
    def data_of(experiments, holdouts = nil)
      payload = { experiments: experiments }
      payload[:holdouts] = holdouts unless holdouts.nil?
      json = JSON.generate(payload)
      DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
    end

    def create_context(data, units: { UNIT_TYPE => UID }, overrides: {}, custom: {})
      config = ContextConfig.create
      config.set_units(units)
      config.set_overrides(overrides)
      config.set_custom_assignments(custom)
      Context.create(clock, config, OpenStruct.new(data_future: data, success?: true), data_provider,
                     event_handler, event_logger, variable_parser, audience_matcher,
                     application: "website", environment: "production")
    end

    def refresh(context, data)
      allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
      context.refresh
    end

    # [id, name, unit, variant, assigned, eligible, overridden, full_on, custom, audience_mismatch, rule_override]
    def exposures_of(context)
      context.publish
      published.flat_map { |event| event.exposures || [] }.map do |e|
        [e.id, e.name, e.unit, e.variant, e.assigned, e.eligible, e.overridden, e.full_on, e.custom,
         e.audience_mismatch, e.rule_override]
      end
    end

    def holdout_exposure(id, name, variant, unit: UNIT_TYPE)
      [id, name, unit, variant, true, true, false, false, false, false, false]
    end

    def own_exposure(id, name, variant, unit: UNIT_TYPE, assigned: true, overridden: false, full_on: false,
                     custom: false, audience_mismatch: false, rule_override: false)
      [id, name, unit, variant, assigned, true, overridden, full_on, custom, audience_mismatch, rule_override]
    end

    it "gives a held-out unit control and exposes only the holdout" do
      context = create_context(data_of([experiment(1, "exp_holdout_in", holdout_ids: [11])],
                                       [holdout(11, "holdout_a", HOLDOUT_A)]))

      expect(context.peek_treatment("exp_holdout_in")).to eq(0)
      expect(context.treatment("exp_holdout_in")).to eq(0)
      expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
    end

    it "exposes a not-held-out unit normally plus the holdout at arm 1" do
      context = create_context(data_of([experiment(1, "exp_holdout_out", holdout_ids: [11])],
                                       [holdout(11, "holdout_a", HOLDOUT_A)]), units: { UNIT_TYPE => UID_NOT_HELD_OUT })

      expect(context.treatment("exp_holdout_out")).to eq(0)
      expect(exposures_of(context)).to eq([own_exposure(1, "exp_holdout_out", 0), holdout_exposure(11, "holdout_a", 1)])
    end

    it "leaves an experiment without holdoutIds alone" do
      context = create_context(data_of([experiment(1, "exp_holdout_in", holdout_ids: [11]),
                                        experiment(2, "exp_not_covered")],
                                       [holdout(11, "holdout_a", HOLDOUT_A)]))

      expect(context.treatment("exp_holdout_in")).to eq(0)
      expect(context.treatment("exp_not_covered")).to eq(NORMAL_VARIANT)
      expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0),
                                           own_exposure(2, "exp_not_covered", NORMAL_VARIANT)])
    end

    describe "union of holdouts" do
      it "suppresses when either holdout holds the unit out and exposes both" do
        context = create_context(data_of([experiment(1, "exp_multi_holdout", holdout_ids: [11, 12])],
                                         [holdout(11, "holdout_a", HOLDOUT_A), holdout(12, "holdout_b", HOLDOUT_B)]))

        expect(context.treatment("exp_multi_holdout")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0), holdout_exposure(12, "holdout_b", 1)])
      end

      it "suppresses when only the higher-id holdout holds the unit out" do
        context = create_context(data_of([experiment(1, "exp_union_high_id_decides", holdout_ids: [11, 12])],
                                         [holdout(11, "holdout_low_id", HOLDOUT_B),
                                          holdout(12, "holdout_high_id", HOLDOUT_A)]))

        expect(context.treatment("exp_union_high_id_decides")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_low_id", 1),
                                             holdout_exposure(12, "holdout_high_id", 0)])
      end

      it "does not suppress when neither holdout holds the unit out" do
        context = create_context(data_of([experiment(1, "exp_multi_holdout_miss", holdout_ids: [11, 12])],
                                         [holdout(11, "holdout_a", HOLDOUT_A), holdout(12, "holdout_b", HOLDOUT_B)]),
                                 units: { UNIT_TYPE => UID_NOT_HELD_OUT })

        expect(context.treatment("exp_multi_holdout_miss")).to eq(0)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_multi_holdout_miss", 0),
                                             holdout_exposure(11, "holdout_a", 1), holdout_exposure(12, "holdout_b", 1)])
      end

      it "resolves holdoutIds in id order whatever the payload order" do
        context = create_context(data_of([experiment(1, "exp_unsorted", holdout_ids: [12, 11])],
                                         [holdout(12, "holdout_b", HOLDOUT_B), holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.treatment("exp_unsorted")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0), holdout_exposure(12, "holdout_b", 1)])
      end

      it "exposes a holdout listed twice in holdoutIds once" do
        context = create_context(data_of([experiment(1, "exp_duplicate_ids", holdout_ids: [11, 11])],
                                         [holdout(11, "holdout_b", HOLDOUT_B)]))

        expect(context.treatment("exp_duplicate_ids")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_duplicate_ids", NORMAL_VARIANT),
                                             holdout_exposure(11, "holdout_b", 1)])
      end

      it "keeps the exposed assignment when a refresh drops the duplicate id" do
        context = create_context(data_of([experiment(1, "exp_duplicate_ids", holdout_ids: [11, 11])],
                                         [holdout(11, "holdout_b", HOLDOUT_B)]))
        expect(context.treatment("exp_duplicate_ids")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        refresh(context, data_of([experiment(1, "exp_duplicate_ids", holdout_ids: [11])],
                                 [holdout(11, "holdout_b", HOLDOUT_B)]))

        expect(context.treatment("exp_duplicate_ids")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)
      end

      it "suppresses a unit held out by two holdouts at once and exposes both at arm 0" do
        context = create_context(
          data_of([experiment(9, "verdict", unit_type: "verdict_unit_type", holdout_ids: [107, 108])],
                  [holdout(107, "holdout_107", [0, 42], unit_type: "verdict_unit_type"),
                   holdout(108, "holdout_108", [0, 55], unit_type: "verdict_unit_type")]),
          units: { "verdict_unit_type" => "dual_holdout_unit_5" }
        )

        expect(context.treatment("verdict")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(107, "holdout_107", 0, unit: "verdict_unit_type"),
                                             holdout_exposure(108, "holdout_108", 0, unit: "verdict_unit_type")])
      end
    end

    it "suppresses a full-on experiment" do
      context = create_context(data_of([experiment(1, "exp_fullon_holdout", full_on_variant: 2, holdout_ids: [11])],
                                       [holdout(11, "holdout_a", HOLDOUT_A)]))

      expect(context.treatment("exp_fullon_holdout")).to eq(0)
    end

    describe "three-arm holdouts" do
      def three_arm_context(seeds)
        create_context(data_of([experiment(1, "non_fullon", holdout_ids: [21]),
                                experiment(2, "fullon", full_on_variant: 2, holdout_ids: [21])],
                               [three_arm_holdout(21, "holdout_three_arm", seeds)]))
      end

      it "holds out full-on and other experiments at arm 0" do
        context = three_arm_context(THREE_ARM_0)

        expect(context.treatment("non_fullon")).to eq(0)
        expect(context.treatment("fullon")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(21, "holdout_three_arm", 0)])
      end

      it "holds out only experiments that are not full-on at arm 1" do
        context = three_arm_context(THREE_ARM_1)

        expect(context.treatment("non_fullon")).to eq(0)
        expect(context.treatment("fullon")).to eq(2)
        expect(exposures_of(context)).to eq([holdout_exposure(21, "holdout_three_arm", 1),
                                             own_exposure(2, "fullon", 2, full_on: true)])
      end

      it "assigns both kinds normally at arm 2" do
        context = three_arm_context(THREE_ARM_2)

        expect(context.treatment("non_fullon")).to eq(NORMAL_VARIANT)
        expect(context.treatment("fullon")).to eq(2)
        expect(exposures_of(context)).to eq([own_exposure(1, "non_fullon", NORMAL_VARIANT),
                                             holdout_exposure(21, "holdout_three_arm", 2),
                                             own_exposure(2, "fullon", 2, full_on: true)])
      end

      it "treats arm 1 of a 4-arm holdout as not held out" do
        four = holdout(21, "holdout_four_arm", [0, 1], split: [0.25, 0.25, 0.25, 0.25])
        context = create_context(data_of([experiment(1, "non_fullon", holdout_ids: [21])], [four]))

        expect(context.treatment("non_fullon")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context).last).to eq(holdout_exposure(21, "holdout_four_arm", 1))
      end

      it "takes the arity from the split, not holdoutType" do
        mislabelled = three_arm_holdout(21, "holdout_three_arm", THREE_ARM_1).merge(holdoutType: "full")
        context = create_context(data_of([experiment(1, "non_fullon", holdout_ids: [21])], [mislabelled]))
        expect(context.treatment("non_fullon")).to eq(0)

        two_arm = holdout(21, "holdout_two_arm", HOLDOUT_B, holdout_type: "all_full_on")
        context = create_context(data_of([experiment(1, "non_fullon", holdout_ids: [21])], [two_arm]))
        expect(context.treatment("non_fullon")).to eq(NORMAL_VARIANT)
      end

      it "lets a 2-arm holdout win the union over a 3-arm one at arm 2" do
        context = create_context(data_of([experiment(1, "exp_union", holdout_ids: [11, 22])],
                                         [holdout(11, "holdout_two_arm", HOLDOUT_A),
                                          three_arm_holdout(22, "holdout_three_arm", THREE_ARM_2)]))

        expect(context.treatment("exp_union")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_two_arm", 0),
                                             holdout_exposure(22, "holdout_three_arm", 2)])
      end

      it "lets a 3-arm holdout at arm 1 win the union over a 2-arm one at arm 1" do
        context = create_context(data_of([experiment(1, "exp_union", holdout_ids: [11, 22])],
                                         [holdout(11, "holdout_two_arm", HOLDOUT_B),
                                          three_arm_holdout(22, "holdout_three_arm", THREE_ARM_1)]))

        expect(context.treatment("exp_union")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_two_arm", 1),
                                             holdout_exposure(22, "holdout_three_arm", 1)])
      end

      it "sends a full-on experiment at arm 1 through the strict audience as arm 2 does" do
        audience = '{"filter":[{"gte":[{"var":"age"},{"value":20}]}]}'
        [[THREE_ARM_1, 1], [THREE_ARM_2, 2]].each do |seeds, arm|
          published.clear
          context = create_context(data_of([experiment(1, "fullon_strict", full_on_variant: 2, holdout_ids: [21],
                                                                             audienceStrict: true, audience: audience)],
                                           [three_arm_holdout(21, "holdout_three_arm", seeds)]))
          context.set_attribute("age", 5)

          expect(context.treatment("fullon_strict")).to eq(0)
          expect(exposures_of(context)).to eq([own_exposure(1, "fullon_strict", 0, assigned: false,
                                                                                   audience_mismatch: true),
                                               holdout_exposure(21, "holdout_three_arm", arm)])
        end
      end
    end

    # As in JS, the experiment still exposes itself unassigned; its holdout can't
    # be computed without the unit, so it neither suppresses nor exposes.
    it "gives control and no holdout exposure when the covered unit type is not set" do
      context = create_context(data_of([experiment(1, "exp_user_holdout", unit_type: "user_id", holdout_ids: [11])],
                                       [holdout(11, "holdout_user", HOLDOUT_A, unit_type: "user_id")]))

      expect(context.peek_treatment("exp_user_holdout")).to eq(0)
      expect(context.treatment("exp_user_holdout")).to eq(0)
      expect(exposures_of(context)).to eq([own_exposure(1, "exp_user_holdout", 0, unit: "user_id", assigned: false)])
    end

    describe "malformed or absent holdouts" do
      it "assigns normally without a holdouts key" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])]))
        expect(context.peek_treatment("exp")).to eq(NORMAL_VARIANT)
      end

      it "ignores a holdoutId that names no holdout" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [999])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp", NORMAL_VARIANT)])
      end

      it "ignores a dangling id next to a valid one" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [12, 11]), experiment(2, "other")],
                                         [holdout(11, "holdout_no_mutate", HOLDOUT_A)]))
        expect(context.treatment("exp")).to eq(0)
        expect(context.treatment("other")).to eq(NORMAL_VARIANT)
        expect(context.data.experiments.first.holdout_ids).to eq([12, 11])
      end

      [["a null entry", nil], ["a non-object entry", 7], ["a null split", { split: nil }],
       ["an empty split", { split: [] }], ["no split", :drop_split], ["a non-numeric split", { split: ["a", "b"] }],
       ["a split with a null", { split: [nil, 1] }], ["a text seed", { seedLo: "111" }],
       ["a fractional id", { id: 11.5 }], ["a non-numeric id", { id: "eleven" }]].each do |label, change|
        it "ignores #{label}" do
          entry = case change
                  when Hash then holdout(11, "holdout_bad", HOLDOUT_A).merge(change)
                  when :drop_split then holdout(11, "holdout_bad", HOLDOUT_A).tap { |h| h.delete(:split) }
                  else change
          end
          context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])], [entry]))

          expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
          expect(exposures_of(context)).to eq([own_exposure(1, "exp", NORMAL_VARIANT)])
        end
      end

      it "keeps a holdout whose nested fields can't be decoded, as JS does" do
        broken = holdout(12, "holdout_broken", HOLDOUT_A, variants: "not a list", applications: 3)
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [12])], [broken]))

        expect(context.data.holdouts.map(&:id)).to eq([12])
        expect(context.treatment("exp")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(12, "holdout_broken", 0)])
      end

      it "hashes a holdout without seeds with seeds 0/0" do
        seedless = holdout(11, "holdout_seedless", HOLDOUT_A).tap { |h| h.delete(:seedHi); h.delete(:seedLo) }
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])], [seedless]))
        arm = VariantAssigner.new(UID).assign([0.1, 0.9], 0, 0)

        context.treatment("exp")
        expect(exposures_of(context).last).to eq(holdout_exposure(11, "holdout_seedless", arm))
      end

      it "keeps a holdout with null variants" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A, variants: nil)]))

        expect(context.treatment("exp")).to eq(0)
      end

      it "drops only an entry that can't be decoded at all" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [[1, 2], holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.data.holdouts.map(&:id)).to eq([11])
        expect(context.treatment("exp")).to eq(0)
      end

      # A JavaScript object key matches 11, 11.0 and "11" alike.
      [[11.0, [11]], ["11", [11]], [11, [11.0]], [11, ["11"]]].each do |id, ids|
        it "matches holdout id #{id.inspect} with holdoutIds #{ids.inspect}" do
          context = create_context(data_of([experiment(1, "exp", holdout_ids: ids)],
                                           [holdout(11, "holdout_a", HOLDOUT_A).merge(id: id)]))

          expect(context.treatment("exp")).to eq(0)
          expect(context.pending_count).to eq(1)
        end
      end

      it "treats a non-array holdouts value or holdoutIds as no coverage" do
        json = JSON.generate(experiments: [experiment(1, "exp", holdout_ids: "11")], holdouts: { id: 11 })
        context = create_context(DefaultContextDataDeserializer.new.deserialize(json, 0, json.length))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
      end
    end

    describe "precedence" do
      it "does not let a custom assignment beat a held-out unit" do
        context = create_context(data_of([experiment(1, "exp_holdout_custom", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]),
                                 custom: { "exp_holdout_custom" => 3 })

        expect(context.peek_treatment("exp_holdout_custom")).to eq(0)
        cached = context.instance_variable_get(:@assignment_cache)["exp_holdout_custom"]
        expect(context.treatment("exp_holdout_custom")).to eq(0)
        expect(context.treatment("exp_holdout_custom")).to eq(0)
        expect(context.pending_count).to eq(1)
        expect(context.instance_variable_get(:@assignment_cache)["exp_holdout_custom"]).to be(cached)
      end

      it "lets an override win and still exposes the holdout, for both arms" do
        [[UID, 0], [UID_NOT_HELD_OUT, 1]].each do |uid, arm|
          published.clear
          context = create_context(data_of([experiment(1, "exp_holdout_override", holdout_ids: [11])],
                                           [holdout(11, "holdout_a", HOLDOUT_A)]),
                                   units: { UNIT_TYPE => uid }, overrides: { "exp_holdout_override" => 3 })

          expect(context.peek_treatment("exp_holdout_override")).to eq(3)
          expect(context.treatment("exp_holdout_override")).to eq(3)
          expect(exposures_of(context)).to eq([own_exposure(1, "exp_holdout_override", 3, assigned: false,
                                                                                           overridden: true),
                                               holdout_exposure(11, "holdout_a", arm)])
        end
      end

      it "suppresses before evaluating a strict audience" do
        context = create_context(data_of([experiment(1, "exp_holdout_audience", holdout_ids: [11], audienceStrict: true,
                                                                                  audience: '{"filter":[{"gte":[{"var":"age"},{"value":20}]}]}')],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        context.set_attribute("age", 5)
        expect(audience_matcher).not_to receive(:evaluate)

        expect(context.peek_treatment("exp_holdout_audience")).to eq(0)
      end

      it "still exposes the holdout of a not-held-out unit that fails a strict audience" do
        context = create_context(data_of([experiment(1, "exp_strict", holdout_ids: [11], audienceStrict: true,
                                                                       audience: '{"filter":[{"gte":[{"var":"age"},{"value":20}]}]}')],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]), units: { UNIT_TYPE => UID_NOT_HELD_OUT })
        context.set_attribute("age", 5)

        expect(context.treatment("exp_strict")).to eq(0)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_strict", 0, assigned: false, audience_mismatch: true),
                                             holdout_exposure(11, "holdout_a", 1)])
      end

      it "lets a matching assign rule win over suppression and still exposes the holdout" do
        context = create_context(data_of([experiment(1, "exp_holdout_rules", holdout_ids: [11],
                                                                               assignmentRules: US_RULE)],
                                         [holdout(11, "holdout_rules_suppression", HOLDOUT_A)]))
        context.set_attribute("country", "US")

        expect(context.treatment("exp_holdout_rules")).to eq(1)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_holdout_rules", 1, assigned: false, rule_override: true),
                                             holdout_exposure(11, "holdout_rules_suppression", 0)])
      end

      it "lets a matching split rule win over suppression" do
        split_rule = JSON.generate(rules: [{ name: "Everyone", type: "split", conditions: nil, environments: [],
                                             percentages: "0/100" }])
        context = create_context(data_of([experiment(1, "exp_holdout_split_rule", holdout_ids: [11],
                                                                                    assignmentRules: split_rule)],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.peek_treatment("exp_holdout_split_rule")).to eq(1)
        expect(context.treatment("exp_holdout_split_rule")).to eq(1)
        expect(context.pending_count).to eq(2)
      end

      it "suppresses while the rule does not match and the rule wins once it does" do
        context = create_context(data_of([experiment(1, "exp_holdout_rules", holdout_ids: [11],
                                                                               assignmentRules: US_RULE)],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        context.set_attribute("country", "GB")

        expect(context.treatment("exp_holdout_rules")).to eq(0)
        expect(context.pending_count).to eq(1)

        context.set_attribute("country", "US")
        expect(context.treatment("exp_holdout_rules")).to eq(1)
        expect(context.pending_count).to eq(2)
      end

      it "suppresses again once the rule stops matching, without another exposure" do
        context = create_context(data_of([experiment(1, "exp_holdout_rules", holdout_ids: [11],
                                                                               assignmentRules: US_RULE)],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        context.set_attribute("country", "US")

        expect(context.treatment("exp_holdout_rules")).to eq(1)
        expect(context.pending_count).to eq(2)

        context.set_attribute("country", "GB")
        expect(context.treatment("exp_holdout_rules")).to eq(0)
        expect(context.peek_treatment("exp_holdout_rules")).to eq(0)
        expect(context.pending_count).to eq(2)
      end
    end

    describe "exposure counting" do
      it "exposes a holdout once for two suppressed experiments" do
        context = create_context(data_of([experiment(1, "exp_shared_a", holdout_ids: [11]),
                                          experiment(2, "exp_shared_b", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.treatment("exp_shared_a")).to eq(0)
        expect(context.treatment("exp_shared_b")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "exposes a holdout once for two experiments that are not suppressed" do
        context = create_context(data_of([experiment(1, "exp_shared_a", holdout_ids: [11]),
                                          experiment(2, "exp_shared_b", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]), units: { UNIT_TYPE => UID_NOT_HELD_OUT })

        context.treatment("exp_shared_a")
        context.treatment("exp_shared_b")
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_shared_a", 0), holdout_exposure(11, "holdout_a", 1),
                                             own_exposure(2, "exp_shared_b", 0)])
      end

      it "reuses the cached suppressed assignment" do
        context = create_context(data_of([experiment(1, "exp_holdout_cache", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.treatment("exp_holdout_cache")).to eq(0)
        expect(context.treatment("exp_holdout_cache")).to eq(0)
        expect(context.pending_count).to eq(1)
      end

      it "keeps one exposure per unit type for a holdout covering two unit types" do
        context = create_context(data_of([experiment(1, "exp_unit_a1", unit_type: "user_id", holdout_ids: [11]),
                                          experiment(2, "exp_unit_b", unit_type: "session_id", holdout_ids: [11]),
                                          experiment(3, "exp_unit_a2", unit_type: "user_id", holdout_ids: [11])],
                                         [holdout(11, "holdout_shared", HOLDOUT_B, unit_type: "user_id")]),
                                 units: { "user_id" => UID, "session_id" => UID })

        %w[exp_unit_a1 exp_unit_b exp_unit_a2].each { |name| expect(context.treatment(name)).to eq(NORMAL_VARIANT) }
        expect(context.pending_count).to eq(5)
        holdout_units = exposures_of(context).select { |e| e[0] == 11 }.map { |e| e[2] }
        expect(holdout_units).to eq(%w[user_id session_id])
      end

      it "hashes the holdout with the covered experiment's unit type, not the holdout's" do
        context = create_context(data_of([experiment(1, "exp", unit_type: "session_id", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A, unit_type: "user_id")]),
                                 units: { "session_id" => UID, "user_id" => UID_NOT_HELD_OUT })

        expect(context.treatment("exp")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0, unit: "session_id")])
      end

      it "keeps both exposures when a logger raises on the first" do
        allow(event_logger).to receive(:handle_event) do |_type, data|
          raise "boom" if data.is_a?(Exposure) && data.id == 11
        end
        context = create_context(data_of([experiment(1, "exp_throwing_logger", holdout_ids: [11, 12])],
                                         [holdout(11, "holdout_a", HOLDOUT_A), holdout(12, "holdout_b", HOLDOUT_B)]))

        expect(context.treatment("exp_throwing_logger")).to eq(0)
        expect(context.pending_count).to eq(2)
        expect(context.treatment("exp_throwing_logger")).to eq(0)
        expect(context.pending_count).to eq(2)
      end

      it "logs the experiment exposure, then each holdout exposure" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11, 12])],
                                         [holdout(11, "holdout_a", HOLDOUT_B), holdout(12, "holdout_b", HOLDOUT_B)]))

        context.treatment("exp")
        names = logged.select { |type, _| type == ContextEventLogger::EVENT_TYPE::EXPOSURE }.map { |_, e| e.name }
        expect(names).to eq(%w[exp holdout_a holdout_b])
      end
    end

    describe "refresh" do
      it "keeps the arm after a same-iteration seed edit and does not expose again" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(1)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])], [holdout(11, "holdout_a", HOLDOUT_B)]))

        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(1)
      end

      it "does not expose again after a cosmetic holdout edit" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp")).to eq(0)

        renamed = holdout(11, "holdout_a_renamed", HOLDOUT_A, applications: [{ name: "website" }],
                                                              variants: [{ name: "Control", config: nil }, { name: "HeldOut", config: nil }])
        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])], [renamed]))

        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(1)
      end

      it "does not duplicate a covered experiment's exposure after a cosmetic edit" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]), units: { UNIT_TYPE => UID_NOT_HELD_OUT })
        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(2)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])], [holdout(11, "holdout_a_renamed", HOLDOUT_A)]))

        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(2)
      end

      it "reassigns once to one new arm after an iteration bump" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])],
                                 [holdout(11, "holdout_a", HOLDOUT_A, iteration: 2)]))

        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(3)
        expect(context.treatment("exp")).to eq(0)
        expect(context.pending_count).to eq(3)
      end

      it "keeps suppression on the pinned arm for an experiment first evaluated after a seed edit" do
        context = create_context(data_of([experiment(1, "exp_a", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp_a")).to eq(0)

        refresh(context, data_of([experiment(1, "exp_a", holdout_ids: [11]), experiment(2, "exp_b", holdout_ids: [11])],
                                 [holdout(11, "holdout_a", HOLDOUT_B)]))

        expect(context.treatment("exp_b")).to eq(0)
        expect(context.treatment("exp_a")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "keeps a 2-arm arm 1 deferring after a same-iteration change to 3 arms" do
        context = create_context(data_of([experiment(1, "exp_a", holdout_ids: [31])],
                                         [holdout(31, "holdout_arity", HOLDOUT_B)]))
        expect(context.treatment("exp_a")).to eq(NORMAL_VARIANT)

        refresh(context, data_of([experiment(1, "exp_a", holdout_ids: [31]), experiment(2, "exp_b", holdout_ids: [31])],
                                 [three_arm_holdout(31, "holdout_arity", THREE_ARM_1)]))

        expect(context.treatment("exp_b")).to eq(NORMAL_VARIANT)
        expect(context.treatment("exp_a")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_a", NORMAL_VARIANT),
                                             holdout_exposure(31, "holdout_arity", 1),
                                             own_exposure(2, "exp_b", NORMAL_VARIANT)])
      end

      it "keeps a 3-arm arm 1 suppressing after a same-iteration change to 2 arms" do
        context = create_context(data_of([experiment(1, "exp_a", holdout_ids: [41])],
                                         [three_arm_holdout(41, "holdout_arity_rev", THREE_ARM_1)]))
        expect(context.treatment("exp_a")).to eq(0)
        expect(context.pending_count).to eq(1)

        refresh(context, data_of([experiment(1, "exp_a", holdout_ids: [41]), experiment(2, "exp_b", holdout_ids: [41])],
                                 [holdout(41, "holdout_arity_rev", HOLDOUT_B)]))

        expect(context.treatment("exp_b")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(41, "holdout_arity_rev", 1)])
      end

      it "publishes the holdout arm of the decision epoch when a logger refreshes in between" do
        context = create_context(data_of([experiment(1, "exp_epoch_race", holdout_ids: [11])],
                                         [holdout(11, "holdout_h", HOLDOUT_B)]))
        next_data = data_of([experiment(1, "exp_epoch_race", holdout_ids: [11])],
                            [holdout(11, "holdout_h", HOLDOUT_A, iteration: 2)])
        allow(event_logger).to receive(:handle_event) do |_type, data|
          refresh(context, next_data) if data.is_a?(Exposure) && data.id == 1
        end

        expect(context.treatment("exp_epoch_race")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_epoch_race", NORMAL_VARIANT),
                                             holdout_exposure(11, "holdout_h", 1)])
      end

      it "does not let a thread that waited on the assignment lock across a refresh expose the arm again" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_h", HOLDOUT_B)]))
        context.peek_treatment("exp")
        lock = context.instance_variable_get(:@assignment_mutex)
        waiting = nil
        lock.synchronize do
          waiting = Thread.new { context.treatment("exp") }
          deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
          Thread.pass until waiting.status == "sleep" || !waiting.alive? ||
                            Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
          expect(waiting.status).to eq("sleep")
          expect(waiting.backtrace.join("\n")).to include("synchronize")

          refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])],
                                   [holdout(11, "holdout_h", HOLDOUT_A, iteration: 2)]))
          context.send(:cached_or_new_assignment, "exp", context.instance_variable_get(:@state)).tap do |current|
            context.queue_exposure(current)
          end
        end
        waiting.join

        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_h", 0)])
      end

      it "re-resolves an overridden experiment when a refresh adds a holdout" do
        context = create_context(data_of([experiment(1, "exp_override_late_holdout")]),
                                 overrides: { "exp_override_late_holdout" => 3 })
        expect(context.treatment("exp_override_late_holdout")).to eq(3)
        expect(context.pending_count).to eq(1)

        refresh(context, data_of([experiment(1, "exp_override_late_holdout", holdout_ids: [11])],
                                 [holdout(11, "holdout_late", HOLDOUT_A)]))

        expect(context.treatment("exp_override_late_holdout")).to eq(3)
        own = own_exposure(1, "exp_override_late_holdout", 3, assigned: false, overridden: true)
        expect(exposures_of(context)).to eq([own, own, holdout_exposure(11, "holdout_late", 0)])
      end

      it "re-resolves an experiment when a refresh removes its coverage" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp")).to eq(0)

        refresh(context, data_of([experiment(1, "exp")], [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0), own_exposure(1, "exp", NORMAL_VARIANT)])
      end

      it "keeps the pinned arm when a refresh spells the holdout id differently" do
        context = create_context(data_of([experiment(1, "exp_a", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.treatment("exp_a")).to eq(0)

        refresh(context, data_of([experiment(1, "exp_a", holdout_ids: [11]), experiment(2, "exp_b", holdout_ids: ["11"])],
                                 [holdout(11, "holdout_a", HOLDOUT_B).merge(id: "11")]))

        expect(context.treatment("exp_b")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      # variable_value walks the key's candidates from the state it started
      # with; a logger callback on the first candidate's exposure refreshes
      # and exposes the second one under the new data before the walk reaches
      # it, the interleaving of a read overlapping a refresh.
      def overlapping_read(context, steps)
        fired = false
        allow(event_logger).to receive(:handle_event) do |_type, data|
          next if fired || !(data.is_a?(Exposure) && data.id == 1)

          fired = true
          steps.call
        end
        context.variable_value("color", "default")
      end

      def shared_key_experiments
        first = experiment(1, "exp_a")
        first[:variants] = [{ name: "A", config: '{"color":"a_control"}' }, { name: "B", config: '{"other":"x"}' }]
        [first, with_variables(experiment(2, "exp_b", holdout_ids: [11]), "color")]
      end

      it "does not let a read that started before a refresh expose the new arm again" do
        context = create_context(data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_B)]))
        result = overlapping_read(context, lambda {
          refresh(context, data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_A, iteration: 2)]))
          expect(context.treatment("exp_b")).to eq(0)
        })
        context.treatment("exp_b")

        expect(result).to eq("control")
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_a", NORMAL_VARIANT), holdout_exposure(11, "holdout_h", 0)])
      end

      it "does not expose an experiment again when a read meets a non-suppressing new arm" do
        context = create_context(data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_A)]))
        result = overlapping_read(context, lambda {
          refresh(context, data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_B, iteration: 2)]))
          expect(context.treatment("exp_b")).to eq(NORMAL_VARIANT)
        })
        context.treatment("exp_b")

        expect(result).to eq("treatment")
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_a", NORMAL_VARIANT),
                                             own_exposure(2, "exp_b", NORMAL_VARIANT), holdout_exposure(11, "holdout_h", 1)])
      end

      it "does not expose an old arm again when a read resumes after the holdout is removed" do
        context = create_context(data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_A)]))
        expect(context.treatment("exp_b")).to eq(0)
        uncovered = shared_key_experiments.tap { |e| e[1].delete(:holdoutIds) }
        result = overlapping_read(context, lambda {
          refresh(context, data_of(shared_key_experiments, [holdout(11, "holdout_h", HOLDOUT_B, iteration: 2)]))
          expect(context.treatment("exp_b")).to eq(NORMAL_VARIANT)
          refresh(context, data_of(uncovered, []))
        })
        context.treatment("exp_b")

        expect(result).to eq("treatment")
        # Removing the coverage re-resolves exp_b once (scenario 225); the
        # iteration 1 arm is never exposed again.
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_h", 0), own_exposure(1, "exp_a", NORMAL_VARIANT),
                                             own_exposure(2, "exp_b", NORMAL_VARIANT), holdout_exposure(11, "holdout_h", 1),
                                             own_exposure(2, "exp_b", NORMAL_VARIANT)])
      end

      it "keeps an exposed assignment when a refresh spells the same holdout id differently" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: ["11"])],
                                 [holdout(11, "holdout_a", HOLDOUT_B).merge(id: "11")]))

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)
      end

      it "names the holdout exposure after the definition the decision was made with" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.peek_treatment("exp")).to eq(0)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11])], [holdout(11, "holdout_renamed", HOLDOUT_A)]))

        expect(context.treatment("exp")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "publishes an integer id for a holdout whose id arrives as text" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_A).merge(id: "11")]))
        context.treatment("exp")
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "keeps the exposed state across a publish" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        context.treatment("exp")
        context.publish
        context.treatment("exp")
        expect(context.pending_count).to eq(0)
      end
    end

    describe "late unit" do
      it "rebuilds an unexposed assignment whose holdout missed the unit" do
        context = create_context(data_of([experiment(1, "exp_null", unit_type: "user_id", full_on_variant: 2,
                                                                      holdout_ids: [11])],
                                         [holdout(11, "holdout_user_id", HOLDOUT_B, unit_type: "user_id")]), units: {})

        expect(context.peek_treatment("exp_null")).to eq(2)
        context.set_unit("user_id", UID)

        expect(context.treatment("exp_null")).to eq(2)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_null", 2, unit: "user_id", full_on: true),
                                             holdout_exposure(11, "holdout_user_id", 1, unit: "user_id")])
      end

      it "keeps an exposed assignment so the experiment is not exposed twice" do
        context = create_context(data_of([experiment(1, "exp_exposed", unit_type: "user_id", full_on_variant: 2,
                                                                         holdout_ids: [11])],
                                         [holdout(11, "holdout_user_id", HOLDOUT_B, unit_type: "user_id")]), units: {})

        expect(context.treatment("exp_exposed")).to eq(2)
        expect(context.pending_count).to eq(1)
        exposed = context.instance_variable_get(:@assignment_cache)["exp_exposed"]

        context.set_unit("user_id", UID)

        expect(context.treatment("exp_exposed")).to eq(2)
        expect(context.pending_count).to eq(1)
        expect(context.instance_variable_get(:@assignment_cache)["exp_exposed"]).to be(exposed)
      end

      it "does not evict for an unrelated unit type" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        context.set_unit("other_unit_type", "some-other-uid")

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)
      end

      it "evicts only the entry that missed the unit" do
        context = create_context(data_of([experiment(1, "exp_late", unit_type: "user_id", full_on_variant: 2,
                                                                      holdout_ids: [11]),
                                          experiment(2, "exp_present", holdout_ids: [12])],
                                         [holdout(11, "holdout_late", HOLDOUT_B, unit_type: "user_id"),
                                          holdout(12, "holdout_present", HOLDOUT_B)]))

        expect(context.peek_treatment("exp_late")).to eq(2)
        expect(context.treatment("exp_present")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        context.set_unit("user_id", UID)

        expect(context.treatment("exp_late")).to eq(2)
        expect(context.pending_count).to eq(4)
        expect(context.treatment("exp_present")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(4)
      end

      it "evicts by the covered experiment's unit type, not the holdout's" do
        context = create_context(data_of([experiment(1, "exp_mismatch", unit_type: "A", full_on_variant: 2,
                                                                          holdout_ids: [11])],
                                         [holdout(11, "holdout_declares_b", HOLDOUT_B, unit_type: "B")]), units: {})

        expect(context.peek_treatment("exp_mismatch")).to eq(2)
        context.set_unit("A", UID)

        expect(context.treatment("exp_mismatch")).to eq(2)
        expect(context.pending_count).to eq(2)
      end

      it "suppresses once a late holdout arm holds the unit out" do
        context = create_context(data_of([experiment(1, "exp_suppresses", unit_type: "user_id", full_on_variant: 2,
                                                                            holdout_ids: [11])],
                                         [holdout(11, "holdout_suppress", HOLDOUT_A, unit_type: "user_id")]), units: {})

        expect(context.peek_treatment("exp_suppresses")).to eq(2)
        context.set_unit("user_id", UID)

        expect(context.treatment("exp_suppresses")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_suppress", 0, unit: "user_id")])
      end

      it "never exposes a holdout that missed the unit of an already exposed assignment" do
        exp = experiment(1, "exp_pinned_null", unit_type: "user_id", full_on_variant: 1, holdout_ids: [11])
        exp[:variants][1] = { name: "B", config: '{"my_var":"value_from_variant"}' }
        context = create_context(data_of([exp], [holdout(11, "holdout_pinned_null", HOLDOUT_A, unit_type: "user_id")]),
                                 units: {})

        expect(context.treatment("exp_pinned_null")).to eq(1)
        expect(context.pending_count).to eq(1)

        context.set_unit("user_id", UID)

        expect(context.variable_value("my_var", "default")).to eq("value_from_variant")
        expect(context.pending_count).to eq(1)
      end

      it "rebuilds once for several holdouts declaring other unit types" do
        context = create_context(data_of([experiment(1, "exp_multi", unit_type: "user_id", full_on_variant: 2,
                                                                       holdout_ids: [11, 12, 13])],
                                         [holdout(11, "holdout_11", HOLDOUT_B, unit_type: "type_x"),
                                          holdout(12, "holdout_12", HOLDOUT_B, unit_type: "type_y"),
                                          holdout(13, "holdout_13", HOLDOUT_B, unit_type: "user_id")]), units: {})

        expect(context.peek_treatment("exp_multi")).to eq(2)
        context.set_unit("user_id", UID)

        expect(context.treatment("exp_multi")).to eq(2)
        expect(context.pending_count).to eq(4)
      end

      it "assigns normally when the unit is set before anything is cached" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]), units: {})
        context.set_unit(UNIT_TYPE, UID)

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
      end

      it "treats setting the same unit again as a no-op" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)

        context.set_unit(UNIT_TYPE, UID)

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(context.pending_count).to eq(2)
      end

      it "keeps a fully resolved unexposed assignment when the same unit is set again" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])],
                                         [holdout(11, "holdout_a", HOLDOUT_B)]))
        expect(context.peek_treatment("exp")).to eq(NORMAL_VARIANT)

        refresh(context, data_of([experiment(1, "exp", holdout_ids: [11], split: [1.0, 0.0])],
                                 [holdout(11, "holdout_a", HOLDOUT_B)]))
        context.set_unit(UNIT_TYPE, UID)

        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp", NORMAL_VARIANT), holdout_exposure(11, "holdout_a", 1)])
      end

      it "recomputes a peeked variable once a late holdout suppresses" do
        exp = experiment(1, "exp_var_late", unit_type: "user_id", full_on_variant: 1, holdout_ids: [11])
        exp[:variants][1] = { name: "B", config: '{"my_var":"value_from_variant"}' }
        context = create_context(data_of([exp], [holdout(11, "holdout_var_late", HOLDOUT_A, unit_type: "user_id")]),
                                 units: {})

        expect(context.peek_variable_value("my_var", "default")).to eq("value_from_variant")
        expect(context.pending_count).to eq(0)

        context.set_unit("user_id", UID)

        expect(context.variable_value("my_var", "default")).to eq("default")
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_var_late", 0, unit: "user_id")])
      end

      it "exposes the holdout of an override once the unit arrives" do
        context = create_context(data_of([experiment(1, "exp_override_late", unit_type: "user_id", holdout_ids: [11])],
                                         [holdout(11, "holdout_override_late", HOLDOUT_B, unit_type: "user_id")]),
                                 units: {}, overrides: { "exp_override_late" => 3 })

        expect(context.peek_treatment("exp_override_late")).to eq(3)
        context.set_unit("user_id", UID)

        expect(context.treatment("exp_override_late")).to eq(3)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_override_late", 3, unit: "user_id", assigned: false,
                                                                                      overridden: true),
                                             holdout_exposure(11, "holdout_override_late", 1, unit: "user_id")])
      end

      it "applies a custom assignment once the unit arrives" do
        context = create_context(data_of([experiment(1, "exp_custom_late", unit_type: "user_id", holdout_ids: [11])],
                                         [holdout(11, "holdout_custom_late", HOLDOUT_B, unit_type: "user_id")]),
                                 units: {}, custom: { "exp_custom_late" => 3 })

        expect(context.peek_treatment("exp_custom_late")).to eq(0)
        context.set_unit("user_id", UID)

        expect(context.treatment("exp_custom_late")).to eq(3)
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_custom_late", 3, unit: "user_id", custom: true),
                                             holdout_exposure(11, "holdout_custom_late", 1, unit: "user_id")])
      end
    end

    # Verdicts computed by java-sdk and the collector (test_holdouts.py
    # TestCollectorHoldoutVerdictVectors) for the same fixtures.
    describe "cross-SDK verdict vectors" do
      def verdict(uid, seeds, split)
        context = create_context(data_of([experiment(9, "verdict", unit_type: "verdict_unit_type", holdout_ids: [107])],
                                         [holdout(107, "holdout_107", seeds, unit_type: "verdict_unit_type", split: split)]),
                                 units: { "verdict_unit_type" => uid })
        context.treatment("verdict")
        exposures_of(context).find { |e| e[0] == 107 }[3]
      end

      signed_seed = -9223372034707292160
      [["façade", [0, 42], [0.1, 0.9], 0],
       ["unicode_emoji_\u{1F680}_0", [0, 42], [0.1, 0.9], 1],
       ["signed_unit_4", [signed_seed >> 32, signed_seed & 0xffffffff], [0.1, 0.9], 0],
       ["signed_unit_b_1", [signed_seed >> 32, signed_seed & 0xffffffff], [0.1, 0.9], 1],
       ["pct1_unit_188", [0, 999999], [0.01, 0.99], 0],
       ["pct1_unit_0", [0, 999999], [0.01, 0.99], 1],
       ["boundary_unit_175653", [0, 42], [0.1, 0.9], 0],
       ["boundary_unit_75792", [0, 42], [0.1, 0.9], 1]].each do |uid, seeds, split, arm|
        it "puts #{uid} in arm #{arm}" do
          expect(verdict(uid, seeds, split)).to eq(arm)
        end
      end
    end

    describe "variables" do
      it "exposes the holdout when a variable is read, for both arms" do
        exp = experiment(1, "exp_var", holdout_ids: [11])
        exp[:variants][1] = { name: "B", config: '{"var_a":"value_a"}' }

        context = create_context(data_of([exp], [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.variable_value("var_a", "default")).to eq("default")
        expect(context.pending_count).to eq(1)

        context = create_context(data_of([exp], [holdout(11, "holdout_a", HOLDOUT_A)]),
                                 units: { UNIT_TYPE => UID_NOT_HELD_OUT })
        expect(context.variable_value("var_a", "default")).to eq("default")
        expect(context.pending_count).to eq(2)
      end

      it "prefers an assigned experiment over a suppressed one with a lower id and exposes both holdouts" do
        suppressed = experiment(1, "exp_var_key_suppressed", holdout_ids: [11])
        suppressed[:variants][1] = { name: "B", config: '{"shared":"from_suppressed"}' }
        assigned = experiment(2, "exp_var_key_assigned")
        assigned[:variants][1] = { name: "B", config: '{"shared":"from_assigned"}' }
        context = create_context(data_of([suppressed, assigned], [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.variable_value("shared", "default")).to eq("from_assigned")
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0),
                                             own_exposure(2, "exp_var_key_assigned", NORMAL_VARIANT)])
      end

      it "queues nothing on peek" do
        suppressed = experiment(1, "exp_peek_suppressed", holdout_ids: [11])
        suppressed[:variants][1] = { name: "B", config: '{"shared_peek":"from_suppressed"}' }
        assigned = experiment(2, "exp_peek_assigned")
        assigned[:variants][1] = { name: "B", config: '{"shared_peek":"from_assigned"}' }
        context = create_context(data_of([suppressed, assigned], [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.peek_variable_value("shared_peek", "default")).to eq("from_assigned")
        expect(context.peek_treatment("exp_peek_suppressed")).to eq(0)
        expect(context.pending_count).to eq(0)
      end

      it "returns the control value, not the default, for a held-out unit" do
        context = create_context(data_of([with_variables(experiment(1, "exp", holdout_ids: [11]), "color")],
                                         [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.peek_variable_value("color", "default")).to eq("control")
        expect(context.variable_value("color", "default")).to eq("control")
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "skips an overridden held-out experiment when picking the control fallback" do
        first = experiment(1, "exp_ov", holdout_ids: [11])
        first[:variants] = [{ name: "A", config: '{"color":"ov_control"}' }, { name: "B", config: '{"other":"x"}' }]
        second = with_variables(experiment(2, "exp_second", holdout_ids: [11]), "color")
        context = create_context(data_of([first, second], [holdout(11, "holdout_a", HOLDOUT_A)]),
                                 overrides: { "exp_ov" => 1 })

        expect(context.peek_variable_value("color", "default")).to eq("control")
      end

      it "skips a rule-won held-out experiment when picking the control fallback" do
        first = experiment(1, "exp_rule", holdout_ids: [11], assignmentRules: US_RULE)
        first[:variants] = [{ name: "A", config: '{"color":"rule_control"}' }, { name: "B", config: '{"other":"x"}' }]
        second = with_variables(experiment(2, "exp_second", holdout_ids: [11]), "color")
        context = create_context(data_of([first, second], [holdout(11, "holdout_a", HOLDOUT_A)]))
        context.set_attribute("country", "US")

        expect(context.peek_variable_value("color", "default")).to eq("control")
      end

      it "keeps the first suppressed experiment's control even when it lacks the key" do
        first = experiment(1, "exp_first", holdout_ids: [11])
        first[:variants] = [{ name: "A", config: '{"other":"x"}' }, { name: "B", config: '{"color":"first"}' }]
        second = with_variables(experiment(2, "exp_second", holdout_ids: [11]), "color")
        context = create_context(data_of([first, second], [holdout(11, "holdout_a", HOLDOUT_A)]))

        expect(context.peek_variable_value("color", "default")).to eq("default")
      end

      it "reads the rule variant of a held-out rule-won experiment" do
        exp = with_variables(experiment(1, "exp_holdout_rules", holdout_ids: [11], assignmentRules: US_RULE), "color")
        context = create_context(data_of([exp], [holdout(11, "holdout_rules_suppression", HOLDOUT_A)]))
        context.set_attribute("country", "US")

        expect(context.variable_value("color", "default")).to eq("treatment")
        expect(exposures_of(context)).to eq([own_exposure(1, "exp_holdout_rules", 1, assigned: false, rule_override: true),
                                             holdout_exposure(11, "holdout_rules_suppression", 0)])
      end

      it "prefers a rule-won experiment over a suppressed one" do
        held_out = with_variables(experiment(1, "exp_held_out", holdout_ids: [11]), "color")
        rule_won = with_variables(experiment(2, "exp_rule_won", holdout_ids: [11], assignmentRules: US_RULE), "color")
        context = create_context(data_of([held_out, rule_won], [holdout(11, "holdout_a", HOLDOUT_A)]))

        context.set_attribute("country", "GB")
        expect(context.peek_variable_value("color", "default")).to eq("control")
        context.set_attribute("country", "US")
        expect(context.peek_variable_value("color", "default")).to eq("treatment")
      end

      it "prefers an earlier assigned experiment over a later rule-won one" do
        assigned = with_variables(experiment(1, "exp_assigned", split: [1.0, 0.0]), "color")
        rule_won = with_variables(experiment(2, "exp_rule_won", assignmentRules: US_RULE), "color")
        context = create_context(data_of([assigned, rule_won], []))
        context.set_attribute("country", "US")

        expect(context.peek_variable_value("color", "default")).to eq("control")
        expect(context.peek_treatment("exp_rule_won")).to eq(1)
      end
    end

    describe "payload" do
      it "decodes holdouts and holdout fields by name and ignores unknown keys at every level" do
        json = JSON.generate(
          experiments: [experiment(1, "exp", holdout_ids: [11], someFutureField: { nested: [1] }),
                        experiment(2, "exp_other", futureArray: [1, 2])],
          holdouts: [holdout(11, "holdout_a", HOLDOUT_A).merge(futureScalar: 1, futureObject: { a: 1 },
                                                               futureArray: [{ b: 2 }],
                                                               variants: [{ name: "A", config: nil, extra: 1 },
                                                                          { name: "B", config: nil }]).to_a.reverse.to_h],
          futureRootField: { x: 1 }
        )
        data = nil
        expect { data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length) }.not_to output.to_stderr

        holdout = data.holdouts.first
        expect([holdout.id, holdout.name, holdout.unit_type, holdout.iteration, holdout.seed_hi, holdout.seed_lo,
                holdout.split, holdout.holdout_type]).to eq([11, "holdout_a", UNIT_TYPE, 1, 13, 111, [0.1, 0.9], "full"])
        expect(data.experiments.first.holdout_ids).to eq([11])

        context = create_context(data)
        expect(context.treatment("exp")).to eq(0)
        expect(context.treatment("exp_other")).to eq(NORMAL_VARIANT)
        expect(logged.map(&:first)).not_to include(ContextEventLogger::EVENT_TYPE::ERROR)
      end

      it "decodes a slim holdout with only the collector's fields" do
        slim = { id: 11, name: "holdout_a", unitType: UNIT_TYPE, iteration: 1, seedHi: 13, seedLo: 111, split: [0.1, 0.9] }
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11])], [slim]))

        expect(context.treatment("exp")).to eq(0)
        expect(exposures_of(context)).to eq([holdout_exposure(11, "holdout_a", 0)])
      end

      it "compares holdout fields in model equality" do
        base = experiment(1, "exp", holdout_ids: [11])
        expect(Experiment.new(base)).to eq(Experiment.new(base))
        expect(Experiment.new(base)).not_to eq(Experiment.new(base.merge(holdoutIds: [12])))
        expect(Experiment.new(base)).not_to eq(Experiment.new(base.merge(holdoutType: "full")))
        expect(ContextData.new([base], [holdout(11, "h", HOLDOUT_A)])).to eq(ContextData.new([base], [holdout(11, "h", HOLDOUT_A)]))
        expect(ContextData.new([base], [holdout(11, "h", HOLDOUT_A)])).not_to eq(ContextData.new([base], [holdout(11, "h", HOLDOUT_B)]))
        expect(ContextData.new([base], [])).not_to eq(ContextData.new([base]))
      end

      it "allocates no holdout state for a context without holdouts" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [11]), experiment(2, "exp_b")]))
        other = create_context(data_of([experiment(1, "exp")], []))
        context.treatment("exp")

        state = context.instance_variable_get(:@state)
        expect(state.holdouts_by_id).to be_frozen.and be_empty
        expect(state.holdouts_by_id).to be(other.instance_variable_get(:@state).holdouts_by_id)
        expect(state.index.values.map(&:holdouts)).to eq([nil, nil])
        expect(context.instance_variable_get(:@holdout_assignments)).to be_nil
      end

      it "does not read holdoutIds when the payload has no holdouts" do
        data = data_of([experiment(1, "exp", holdout_ids: [11])])
        expect(data.experiments.first).not_to receive(:holdout_ids)
        create_context(data)
      end

      it "gives a covered experiment with only dangling ids no holdout list" do
        context = create_context(data_of([experiment(1, "exp", holdout_ids: [99])], [holdout(11, "holdout_a", HOLDOUT_A)]))
        expect(context.instance_variable_get(:@state).index[:exp].holdouts).to be_nil
      end

      it "builds the same data as before without holdouts" do
        data = data_of([experiment(1, "exp")])
        expect(data.instance_variables).to eq([:@experiments])
        expect(data).to eq(ContextData.new([experiment(1, "exp")]))
        expect(data.experiments.first.instance_variables).not_to include(:@holdout_ids, :@holdout_type)
      end

      it "accepts data objects that predate holdouts" do
        legacy = Struct.new(:experiments).new([Experiment.new(experiment(1, "exp"))])
        context = create_context(legacy)
        expect(context.treatment("exp")).to eq(NORMAL_VARIANT)
      end

      it "publishes the same body without holdouts as with an empty holdouts array" do
        bodies = [nil, []].map do |holdouts|
          published.clear
          context = create_context(data_of([experiment(1, "exp", holdout_ids: [11]), experiment(2, "exp_b")], holdouts))
          context.treatment("exp")
          context.treatment("exp_b")
          context.publish
          DefaultContextEventSerializer.new.serialize(published.first)
        end
        expect(bodies[1]).to eq(bodies[0])
        expect(JSON.parse(bodies[0])["exposures"].map { |e| e["name"] }).to eq(%w[exp exp_b])
      end
    end
  end
end
