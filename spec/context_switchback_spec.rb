# frozen_string_literal: true

require "switchback_support"

# Port of java-sdk ContextSwitchbackTest (core-api/src/test/java/com/absmartly/sdk/ContextSwitchbackTest.java).
module ContextSwitchbackSpec
  RSpec.describe "Context switchbacks" do
    include SwitchbackSpecSupport

    UNIT_TYPE = "store_id"
    UID = "e791e240fcd3df7d238cfc285f475e8152fcc0ec"
    # Hashing.hash_unit(UID): the MD5/base64url string the Collector also produces.
    UID_HASH = "pAE3a1i5Drs5mKRNq56adA"
    HOUR = SwitchbackSpecSupport::HOUR
    DAY = SwitchbackSpecSupport::DAY
    ANCHOR = SwitchbackSpecSupport::ANCHOR
    SEED_HI = -5
    SEED_LO = -7
    CLUSTER_PATH = "store_key"
    CLUSTER_KEY = "store-42"
    # Periods 0..11 of the raw key "store-42" under seed (SEED_HI, SEED_LO), from java-sdk's
    # independent Python reference.
    EXPECTED_2_ARMS = [0, 1, 0, 1, 1, 0, 1, 0, 1, 0, 0, 1].freeze
    EXPECTED_3_ARMS = [0, 2, 1, 2, 1, 0, 1, 2, 0, 1, 0, 2].freeze
    EXPECTED_10_ARMS = [8, 3, 7, 4, 2, 0, 5, 1, 9, 6, 3, 7].freeze
    # The same reference fed UID_HASH and the raw UID: what keying by the unit would serve.
    UID_HASH_3_ARMS = [1, 2, 0, 2, 1, 0, 2, 0, 1, 1, 2, 0].freeze
    UID_3_ARMS = [2, 0, 1, 0, 1, 2, 1, 2, 0, 0, 1, 2].freeze
    ASSIGN_VARIANT_1 = '{"rules":[{"type":"assign","environments":[],"variant":1}]}'
    ASSIGN_VARIANT_2 = '{"rules":[{"type":"assign","environments":[],"variant":2}]}'
    # An audience the default context never matches (no "tier" attribute).
    STRICT_GOLD_AUDIENCE = '{"filter":[{"eq":[{"var":"tier"},{"value":"gold"}]}]}'

    let(:clock) { SwitchbackSpecSupport::MutableClock.new(ANCHOR) }
    let(:provider) { double("ContextDataProvider") }

    def switchback(id = 1, name = "exp_sb", arms = 2, period_ms = HOUR, **extra)
      {
        id: id, name: name, unitType: UNIT_TYPE, iteration: 1, seedHi: SEED_HI, seedLo: SEED_LO,
        split: Array.new(arms) { 1.0 / arms },
        variants: Array.new(arms) { |i| { name: ("A".ord + i).chr, config: "{\"sb.arm\":#{i}}" } },
        trafficSeedHi: 1, trafficSeedLo: 2, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }], audienceStrict: false, audience: nil,
        randomizationType: "switchback", switchbackClusters: { UNIT_TYPE => CLUSTER_PATH },
        switchbackStartAt: ANCHOR, switchbackPeriodMs: period_ms, switchbackCarryoverDurationMs: 0,
        switchbackBurnInDurationMs: 0, switchbackBurnOutDurationMs: 0, switchbackDesignType: "balanced_block",
        switchbackEstimand: "global_average_treatment_effect"
      }.merge(extra)
    end

    def unit_twin(experiment)
      experiment.merge(randomizationType: nil, switchbackClusters: nil, switchbackStartAt: nil,
                       switchbackPeriodMs: nil)
    end

    def create_context(experiments, units: { UNIT_TYPE => UID }, holdouts: nil, **options)
      build_context(data_of(experiments, holdouts), units: units, attributes: { CLUSTER_PATH => CLUSTER_KEY },
                                                    provider: provider, **options)
    end

    def refresh_to(context, experiments, holdouts = nil)
      allow(provider).to receive(:context_data).and_return(ready(data_of(experiments, holdouts)))
      context.refresh
    end

    def sb_exposure(id, name, variant, exposed_at, assigned, eligible)
      exposure(id, name, UNIT_TYPE, variant, exposed_at, assigned, eligible)
    end

    def rule_exposure(name, variant, exposed_at)
      exposure(1, name, UNIT_TYPE, variant, exposed_at, false, true, false, false, false, false, true)
    end

    def strict_mismatch_exposure(exposed_at)
      exposure(1, "exp_sb", UNIT_TYPE, 0, exposed_at, false, true, false, false, false, true, false)
    end

    def peek_schedule(context, name, period_ms, periods)
      Array.new(periods) do |i|
        clock.now = ANCHOR + i * period_ms
        context.peek_treatment(name)
      end
    end

    def seed
      (SEED_HI << 32) | (SEED_LO & 0xffffffff)
    end

    def serialized_publish(context)
      publisher = context.send(:event_handler)
      context.publish
      DefaultContextEventSerializer.new.serialize(publisher.events.last)
    end

    it "keys the cluster by the raw cluster value, neither hashed nor the unit uid" do
      expect(Hashing.hash_unit(UID)).to eq(UID_HASH)

      context = create_context([switchback(1, "exp_sb", 3)])
      served = peek_schedule(context, "exp_sb", HOUR, 12)

      expect(served).to eq(EXPECTED_3_ARMS)
      expect(served).not_to eq(UID_HASH_3_ARMS)
      expect(served).not_to eq(UID_3_ARMS)
      hashed = Hashing.hash_unit(CLUSTER_KEY)
      expect(served).to eq((0...12).map { |i| Absmartly::Switchback::Assigner.assign(CLUSTER_KEY, i, seed, 3) })
      expect((0...12).map { |i| Absmartly::Switchback::Assigner.assign(hashed, i, seed, 3) }).not_to eq(served)
    end

    it "serves two, three and ten arm permutations" do
      context = create_context([switchback(1, "exp_2", 2), switchback(2, "exp_3", 3), switchback(3, "exp_10", 10)])

      expect(peek_schedule(context, "exp_2", HOUR, 12)).to eq(EXPECTED_2_ARMS)
      expect(peek_schedule(context, "exp_3", HOUR, 12)).to eq(EXPECTED_3_ARMS)
      expect(peek_schedule(context, "exp_10", HOUR, 12)).to eq(EXPECTED_10_ARMS)
    end

    it "changes period at the exact one-hour edge milliseconds" do
      context = create_context([switchback])
      [[ANCHOR - 1, 0], [ANCHOR, EXPECTED_2_ARMS[0]], [ANCHOR + HOUR - 1, EXPECTED_2_ARMS[0]],
       [ANCHOR + HOUR, EXPECTED_2_ARMS[1]], [ANCHOR + 3 * HOUR - 1, EXPECTED_2_ARMS[2]],
       [ANCHOR + 3 * HOUR, EXPECTED_2_ARMS[3]]].each do |now, expected|
        clock.now = now
        expect(context.peek_treatment("exp_sb")).to eq(expected), now.to_s
      end
    end

    it "changes period at the exact 24-hour edge milliseconds" do
      context = create_context([switchback(1, "exp_sb", 2, DAY)])
      [[ANCHOR - 1, 0], [ANCHOR, EXPECTED_2_ARMS[0]], [ANCHOR + HOUR, EXPECTED_2_ARMS[0]],
       [ANCHOR + DAY - 1, EXPECTED_2_ARMS[0]], [ANCHOR + DAY, EXPECTED_2_ARMS[1]],
       [ANCHOR + 4 * DAY - 1, EXPECTED_2_ARMS[3]], [ANCHOR + 4 * DAY, EXPECTED_2_ARMS[4]]].each do |now, expected|
        clock.now = now
        expect(context.peek_treatment("exp_sb")).to eq(expected), now.to_s
      end
    end

    # The anchor is used as served, never rounded; before it the experiment is a silent
    # control. An anchor that is not hour aligned is unservable in every period.
    it "treats an unaligned start as unservable and pre-anchor as ineligible" do
      start = ANCHOR + 1_234_567
      context = create_context([switchback(1, "exp_aligned", 2, HOUR, switchbackStartAt: ANCHOR + HOUR),
                                switchback(2, "exp_unaligned", 2, HOUR, switchbackStartAt: start)])

      [ANCHOR, start - 1, start, ANCHOR + HOUR - 1].each do |now|
        clock.now = now
        expect(context.treatment("exp_aligned")).to eq(0)
        expect(context.treatment("exp_unaligned")).to eq(0)
      end
      expect(context.pending_count).to eq(0)
      (1...4).each do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_aligned")).to eq(EXPECTED_2_ARMS[i - 1])
        expect(context.treatment("exp_unaligned")).to eq(0)
        clock.now = start + i * HOUR
        expect(context.treatment("exp_unaligned")).to eq(0)
      end

      expect(published_exposures(context)).to eq([
        sb_exposure(1, "exp_aligned", EXPECTED_2_ARMS[0], ANCHOR + HOUR, true, true),
        sb_exposure(1, "exp_aligned", EXPECTED_2_ARMS[1], ANCHOR + 2 * HOUR, true, true),
        sb_exposure(1, "exp_aligned", EXPECTED_2_ARMS[2], ANCHOR + 3 * HOUR, true, true)
      ])
    end

    # The Collector Registry's anchor bounds: hour aligned and in [0, 10000-01-01T00:00:00Z).
    it "treats an anchor off the hour or out of range as unservable" do
      max_anchor = 253_402_300_800_000
      long_max = (2**63) - 1
      [ANCHOR + 1, ANCHOR - 1, ANCHOR + 30 * 60_000, ANCHOR + HOUR - 1, -HOUR, -1, max_anchor,
       max_anchor + HOUR, long_max - (long_max % HOUR), nil, "1767225600000", ANCHOR.to_f].each do |start_at|
        clock.now = 0
        context = create_context([switchback(switchbackStartAt: start_at)])
        [0, ANCHOR, ANCHOR + 2 * HOUR + 1, start_at.is_a?(Integer) ? start_at : ANCHOR,
         (start_at.is_a?(Integer) ? start_at : ANCHOR) + HOUR, max_anchor + DAY].each do |now|
          clock.now = now
          expect(context.treatment("exp_sb")).to eq(0), "start_at #{start_at.inspect} now #{now}"
          expect(context.variable_value("sb.arm", -1)).to eq(0)
        end
        expect(context.pending_count).to eq(0), "start_at #{start_at.inspect}"
        expect(published_exposures(context)).to eq([])
      end

      # In-range hour-aligned anchors, 0 and the last hour before the bound included, serve.
      [0, ANCHOR, max_anchor - HOUR].each do |start_at|
        clock.now = start_at + HOUR
        context = create_context([switchback(switchbackStartAt: start_at)])
        expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[1]), start_at.to_s
        expect(context.pending_count).to eq(1)
      end
    end

    # The period index is exact 64-bit integer arithmetic, far beyond 2**53.
    it "draws an exact period index in the far future" do
      long_max = (2**63) - 1
      context = create_context([switchback(1, "exp_sb", 3, 1)])
      [2**53 + 1, 2**62 + 3, long_max].each do |now|
        clock.now = now
        expect(context.peek_treatment("exp_sb"))
          .to eq(Absmartly::Switchback::Assigner.assign(CLUSTER_KEY, now - ANCHOR, seed, 3)), now.to_s
      end
    end

    it "never falls back to unit assignment with a null start" do
      context = create_context([switchback(switchbackStartAt: nil)])
      4.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(0)
        # Variant 0's own config, like any ineligible assignment.
        expect(context.variable_value("sb.arm", -1)).to eq(0)
      end
      expect(context.pending_count).to eq(0)
    end

    it "caches the period and rolls over to the next with one exposure each" do
      context = create_context([switchback])

      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)
      clock.now = ANCHOR + HOUR - 1
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.peek_treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)

      clock.now = ANCHOR + HOUR
      expect(context.peek_treatment("exp_sb")).to eq(EXPECTED_2_ARMS[1])
      expect(context.pending_count).to eq(1)
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[1])
      expect(context.pending_count).to eq(2)
      clock.now = ANCHOR + HOUR + 30 * 60_000
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[1])
      expect(context.pending_count).to eq(2)

      expect(published_exposures(context)).to eq([
        sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR + 10, true, true),
        sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[1], ANCHOR + HOUR, true, true)
      ])
    end

    it "follows the period on variable lookups and exposes once per period" do
      context = create_context([switchback(1, "exp_sb", 3)])

      expect(context.variable_keys_list).to eq({ "sb.arm": ["exp_sb"] })
      expect(context.experiments).to eq(["exp_sb"])
      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.peek_variable_value("sb.arm", -1)).to eq(EXPECTED_3_ARMS[i])
        expect(context.variable_value("sb.arm", -1)).to eq(EXPECTED_3_ARMS[i])
        expect(context.variable_value("sb.arm", -1)).to eq(EXPECTED_3_ARMS[i])
        expect(context.treatment("exp_sb")).to eq(EXPECTED_3_ARMS[i])
      end
      expect(context.pending_count).to eq(3)
    end

    # No unit of a linked type: the experiment does not apply. unitType is never a fallback.
    it "leaves a missing cluster unit unassigned without a fallback" do
      context = create_context([switchback(unitType: "user_id")], units: { "user_id" => UID })

      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.peek_treatment("exp_sb")).to eq(0)
        expect(context.treatment("exp_sb")).to eq(0)
        expect(context.variable_value("sb.arm", -1)).to eq(-1)
      end
      expect(context.pending_count).to eq(0)

      # Setting a linked unit later makes the experiment apply.
      context.set_unit(UNIT_TYPE, UID)
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[2])
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[2], ANCHOR + 2 * HOUR,
                                                              true, true)])
    end

    it "serves the full-on variant in every period" do
      context = create_context([switchback(1, "exp_sb", 3, HOUR, fullOnVariant: 2)])
      4.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(2)
      end
      exposures = published_exposures(context)
      expect(exposures.length).to eq(4)
      expect(exposures.map { |e| [e.variant, e.full_on] }.uniq).to eq([[2, true]])
    end

    it "lets an override and a custom assignment win in every period" do
      context = create_context([switchback(1, "exp_override", 3), switchback(2, "exp_custom", 3)])
      context.set_override("exp_override", 7)
      context.set_custom_assignment("exp_custom", 2)

      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_override")).to eq(7)
        expect(context.treatment("exp_custom")).to eq(2)
      end
      exposures = published_exposures(context)
      expect(exposures.length).to eq(6)
      exposures.each do |e|
        expect(e.name == "exp_override" ? [e.overridden, e.variant] : [e.custom, e.variant])
          .to eq(e.name == "exp_override" ? [true, 7] : [true, 2])
      end
    end

    # Traffic uses the serving unit's traffic hash: it matches a unit twin with the same traffic
    # seed and stays fixed across periods.
    it "keeps traffic eligibility sticky per serving unit" do
      counts = Hash.new(0)
      24.times do |u|
        clock.now = ANCHOR
        sb = switchback(1, "exp_sb", 2, HOUR, trafficSplit: [0.5, 0.5])
        twin = switchback(2, "exp_unit", 2, HOUR, trafficSplit: [0.5, 0.5], randomizationType: nil,
                                                  switchbackStartAt: nil)
        context = create_context([sb, twin], units: { UNIT_TYPE => "store_#{u}" })
        context.treatment("exp_unit")
        4.times do |i|
          clock.now = ANCHOR + i * HOUR
          context.treatment("exp_sb")
        end

        exposures = published_exposures(context)
        expect(exposures.length).to eq(5)
        twin_eligible = exposures[0].eligible
        exposures[1..].each do |e|
          expect(e.name).to eq("exp_sb")
          expect(e.eligible).to eq(twin_eligible)
          expect(e.variant).to eq(0) unless twin_eligible
        end
        counts[twin_eligible] += 1
      end
      expect(counts[true]).to be > 0
      expect(counts[false]).to be > 0
    end

    it "leaves unit experiments unaffected" do
      context = create_context([switchback(randomizationType: "unit"),
                                switchback(2, "exp_absent", 2, HOUR, randomizationType: nil)])
      variant = context.treatment("exp_sb")
      absent = context.treatment("exp_absent")
      (1...6).each do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(variant)
        expect(context.treatment("exp_absent")).to eq(absent)
      end
      expect(context.pending_count).to eq(2)
    end

    it "re-resolves when grid fields change on refresh, but not for analysis-only fields" do
      context = create_context([switchback])
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)

      refresh_to(context, [switchback(switchbackBurnInDurationMs: 600_000, switchbackBurnOutDurationMs: 300_000,
                                      switchbackCarryoverDurationMs: 900_000, switchbackEstimand: "other")])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)

      # Period index 0 under both grids, so only the config comparison can invalidate.
      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR)])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(2)

      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackDesignType: "other_design")])
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(3)

      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, randomizationType: "unit")])
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(4)

      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR)])
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(5)

      # The cluster map (types, paths and their order) and the allow-list are identity.
      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackClusters: { UNIT_TYPE => "'store_key'" })])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(6)

      link_added = { UNIT_TYPE => "'store_key'", "device_id" => "city" }
      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackClusters: link_added)])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(7)

      reordered = { "device_id" => "city", UNIT_TYPE => "'store_key'" }
      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackClusters: reordered)])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(8)

      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackClusters: reordered,
                                                                switchbackClusterValues: [CLUSTER_KEY])])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(9)

      # An unrelated unitType edit is not identity: switchbacks never read it.
      refresh_to(context, [switchback(1, "exp_sb", 2, 2 * HOUR, switchbackClusters: reordered,
                                                                switchbackClusterValues: [CLUSTER_KEY],
                                                                unitType: "anything")])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(9)
    end

    it "starts the grid when a refresh sets the start" do
      context = create_context([switchback(switchbackStartAt: nil)])
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(0)

      refresh_to(context, [switchback])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)
    end

    def holdout(split)
      { id: 11, name: "holdout_a", unitType: UNIT_TYPE, iteration: 1, seedHi: 13, seedLo: 111, split: split,
        trafficSeedHi: 0, trafficSeedLo: 0, trafficSplit: [0.0, 1.0], fullOnVariant: 0, applications: [],
        variants: split.each_index.map { |i| { name: i.to_s, config: nil } }, audienceStrict: false,
        audience: nil }
    end

    # Holdouts never apply: one that would hold the unit out neither suppresses the switchback
    # nor records its own exposure through it.
    it "never applies a holdout to a switchback" do
      # split [0.1, 0.9] gives UID arm 0 (held out) for an ordinary experiment.
      context = create_context([switchback(holdoutIds: [11])], holdouts: [holdout([0.1, 0.9])])
      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[i])
        expect(context.variable_value("sb.arm", -1)).to eq(EXPECTED_2_ARMS[i])
      end

      expect(published_exposures(context)).to eq([
        sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR, true, true),
        sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[1], ANCHOR + HOUR, true, true),
        sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[2], ANCHOR + 2 * HOUR, true, true)
      ])
    end

    it "resolves no holdouts for a switchback" do
      context = create_context([switchback(holdoutIds: [11]), unit_twin(switchback(2, "exp_unit", holdoutIds: [11]))],
                               holdouts: [holdout([0.1, 0.9])])
      expect(context.send(:experiment, "exp_sb").holdouts).to be_nil
      expect(context.send(:experiment, "exp_unit").holdouts.map(&:id)).to eq([11])
    end

    it "would hold the unit out of the same experiment as a unit experiment" do
      context = create_context([unit_twin(switchback(holdoutIds: [11]))], holdouts: [holdout([0.1, 0.9])])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(published_exposures(context).map(&:name)).to eq(["holdout_a"])
    end

    # Rules come first, before the anchor too, with ruleOverride set and the exposure recorded.
    it "lets an assignment rule override the schedule" do
      10.times do |u|
        clock.now = ANCHOR - 1
        context = create_context([switchback(assignmentRules: ASSIGN_VARIANT_1)], units: { UNIT_TYPE => "user-#{u}" })
        expect(context.treatment("exp_sb")).to eq(1)
        expect(context.variable_value("sb.arm", -1)).to eq(1)
        4.times do |i|
          clock.now = ANCHOR + i * HOUR
          expect(context.treatment("exp_sb")).to eq(1)
        end
        exposures = published_exposures(context)
        expect(exposures).to eq([rule_exposure("exp_sb", 1, ANCHOR - 1)] +
                                (0...4).map { |i| rule_exposure("exp_sb", 1, ANCHOR + i * HOUR) })
      end
    end

    # An unservable schedule only replaces the draw: full-on and a matching rule still apply.
    it "lets full-on and rules apply on an unservable schedule" do
      context = create_context([switchback(1, "sb_full_on", 2, HOUR, switchbackStartAt: nil, fullOnVariant: 1),
                                switchback(2, "sb_rules", 2, HOUR, switchbackPeriodMs: 0,
                                                                   assignmentRules: ASSIGN_VARIANT_1),
                                switchback(3, "sb_unaligned_rules", 2, HOUR, switchbackStartAt: ANCHOR + 1,
                                                                             assignmentRules: ASSIGN_VARIANT_1)],
                               units: { UNIT_TYPE => "15" })

      expect(context.treatment("sb_full_on")).to eq(1)
      expect(context.treatment("sb_rules")).to eq(1)
      expect(context.treatment("sb_unaligned_rules")).to eq(1)
      expect(published_exposures(context)).to eq([
        exposure(1, "sb_full_on", UNIT_TYPE, 1, ANCHOR, true, true, false, true, false, false, false),
        exposure(2, "sb_rules", UNIT_TYPE, 1, ANCHOR, false, true, false, false, false, false, true),
        exposure(3, "sb_unaligned_rules", UNIT_TYPE, 1, ANCHOR, false, true, false, false, false, false, true)
      ])
    end

    it "never evaluates rules for an ineligible cluster" do
      context = create_context([switchback(assignmentRules: ASSIGN_VARIANT_1, switchbackClusterValues: ["other-store"])])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)
    end

    # A split rule randomizes over the serving unit, not over the payload's unitType.
    it "randomizes a split rule over the serving unit" do
      rules = '{"rules":[{"type":"split","environments":[],"percentages":"50/50"}]}'
      ones = 0
      32.times do |u|
        uid = "store-#{u}"
        expected = VariantAssigner.new(uid).assign([0.5, 0.5], SEED_HI, SEED_LO)
        context = create_context([switchback(unitType: "user_id", assignmentRules: rules)],
                                 units: { UNIT_TYPE => uid, "user_id" => "fixed-user" })
        expect(context.treatment("exp_sb")).to eq(expected), uid
        expect(published_exposures(context)).to eq([rule_exposure("exp_sb", expected, ANCHOR)])
        ones += expected
      end
      expect(ones).to be_between(1, 31)
    end

    it "records a strict audience mismatch as control" do
      context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)])
      clock.now = ANCHOR + HOUR
      expect(context.treatment("exp_sb")).to eq(0)
      expect(published_exposures(context)).to eq([strict_mismatch_exposure(ANCHOR + HOUR)])
    end

    # Period 1 draws 1, so the variant 0 below is the strict mismatch's control.
    it "serializes a strict audience mismatch exposure exactly" do
      context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)])
      expect(EXPECTED_2_ARMS[1]).to eq(1)
      clock.now = ANCHOR + HOUR + 5
      context.treatment("exp_sb")
      clock.now = ANCHOR + HOUR + 9

      expect(JSON.parse(serialized_publish(context))).to eq(
        "publishedAt" => ANCHOR + HOUR + 9, "units" => [{ "type" => UNIT_TYPE, "uid" => UID_HASH }], "hashed" => true,
        "exposures" => [{ "id" => 1, "name" => "exp_sb", "unit" => UNIT_TYPE, "exposedAt" => ANCHOR + HOUR + 5,
                          "variant" => 0, "assigned" => false, "eligible" => true, "overridden" => false,
                          "fullOn" => false, "custom" => false, "audienceMismatch" => true,
                          "ruleOverride" => false }],
        "attributes" => [{ "name" => CLUSTER_PATH, "value" => CLUSTER_KEY, "setAt" => ANCHOR }]
      )
    end

    # The audience comes before the period check, so a strict mismatch before the anchor or with an
    # unservable schedule is recorded.
    it "records a strict audience mismatch before the anchor and on an unservable schedule" do
      clock.now = ANCHOR - 1
      context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(published_exposures(context)).to eq([strict_mismatch_exposure(ANCHOR - 1)])

      clock.now = ANCHOR + HOUR + 3
      context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true,
                                           switchbackStartAt: nil)])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(published_exposures(context)).to eq([strict_mismatch_exposure(ANCHOR + HOUR + 3)])
    end

    # The legacy path returns an ineligible control before the audience is evaluated.
    it "records nothing for a strict mismatch with a missing or unreadable cluster map" do
      [nil, { UNIT_TYPE => "'geo" }].each do |clusters|
        clock.now = ANCHOR + HOUR + 3
        context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true,
                                             switchbackClusters: clusters)])
        expect(context.treatment("exp_sb")).to eq(0)
        expect(context.pending_count).to eq(0), clusters.inspect
      end
    end

    # A strict-mismatched switchback is not assigned, so on a shared variable key the next
    # experiment that declares the key wins, as for a unit experiment. As for a unit experiment in
    # this SDK (and the JavaScript SDK), every experiment visited on the way is exposed; java-sdk
    # exposes only the winner.
    it "gives way on a shared variable key when strict-mismatched" do
      sb = switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)
      unit = unit_twin(switchback(2, "exp_unit", 2, HOUR, fullOnVariant: 1,
                                                          variants: [{ name: "A", config: '{"sb.arm":10}' },
                                                                     { name: "B", config: '{"sb.arm":11}' }]))
      clock.now = ANCHOR + HOUR + 3
      context = create_context([sb, unit])
      expect(context.variable_keys_list).to eq({ "sb.arm": %w[exp_sb exp_unit] })

      expect(context.peek_variable_value("sb.arm", -1)).to eq(11)
      expect(context.pending_count).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(11)
      expect(published_exposures(context)).to eq([
        strict_mismatch_exposure(ANCHOR + HOUR + 3),
        exposure(2, "exp_unit", UNIT_TYPE, 1, ANCHOR + HOUR + 3, true, true, false, true, false, false, false)
      ])
    end

    it "returns the default value for a strict-mismatched switchback alone on a variable key" do
      clock.now = ANCHOR + HOUR + 3
      context = create_context([switchback(audience: STRICT_GOLD_AUDIENCE, audienceStrict: true)])
      expect(context.peek_variable_value("sb.arm", -1)).to eq(-1)
      expect(context.pending_count).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(-1)
    end

    # The SWITCHBACK.md "Exposure flags" table: [assigned, eligible, overridden, full_on, custom,
    # audience_mismatch, rule_override], and the variant served at ANCHOR + 2h + 3 (period 2, whose
    # 3-arm draw is 1). Forced variants are 2, which differs from both control and the draw.
    PARITY = {
      override: [[false, true, true, false, false, false, false], 2],
      override_over_strict_mismatch: [[false, true, true, false, false, false, false], 2],
      rule: [[false, true, false, false, false, false, true], 2],
      rule_over_strict_mismatch: [[false, true, false, false, false, false, true], 2],
      strict_mismatch: [[false, true, false, false, false, true, false], 0],
      strict_mismatch_over_full_on: [[false, true, false, false, false, true, false], 0],
      strict_mismatch_over_traffic_miss: [[false, true, false, false, false, true, false], 0],
      non_strict_mismatch: [[true, true, false, false, false, true, false], EXPECTED_3_ARMS[2]],
      full_on: [[true, true, false, true, false, false, false], 2],
      traffic_miss: [[true, false, false, false, false, false, false], 0],
      custom: [[true, true, false, false, true, false, false], 2],
      draw: [[true, true, false, false, false, false, false], EXPECTED_3_ARMS[2]]
    }.freeze

    def configure_branch(branch, experiment)
      strict = { audience: STRICT_GOLD_AUDIENCE, audienceStrict: true }
      extra = case branch
              when :override_over_strict_mismatch, :strict_mismatch then strict
              when :rule_over_strict_mismatch then strict.merge(assignmentRules: ASSIGN_VARIANT_2)
              when :rule then { assignmentRules: ASSIGN_VARIANT_2 }
              when :strict_mismatch_over_full_on then strict.merge(fullOnVariant: 2)
              when :strict_mismatch_over_traffic_miss then strict.merge(trafficSplit: [1.0, 0.0])
              when :non_strict_mismatch then { audience: STRICT_GOLD_AUDIENCE }
              when :full_on then { fullOnVariant: 2 }
              when :traffic_miss then { trafficSplit: [1.0, 0.0] }
              else {}
      end
      experiment.merge(extra)
    end

    def expose_once(experiment, branch)
      overrides = %i[override override_over_strict_mismatch].include?(branch) ? { "exp_parity" => 2 } : {}
      custom = branch == :custom ? { "exp_parity" => 2 } : {}
      context = create_context([configure_branch(branch, experiment)], overrides: overrides, custom: custom)
      context.treatment("exp_parity")
      exposures = published_exposures(context)
      expect(exposures.length).to eq(1), branch.to_s
      exposures[0]
    end

    def flags(e)
      [e.assigned, e.eligible, e.overridden, e.full_on, e.custom, e.audience_mismatch, e.rule_override]
    end

    PARITY.each do |branch, (expected_flags, expected_variant)|
      it "publishes the same exposure flags as a unit experiment for #{branch}" do
        clock.now = ANCHOR + 2 * HOUR + 3
        expect(EXPECTED_3_ARMS[2]).to eq(1)

        unit = expose_once(unit_twin(switchback(1, "exp_parity", 3)), branch)
        sb = expose_once(switchback(1, "exp_parity", 3), branch)

        expect(flags(unit)).to eq(expected_flags)
        expect(flags(sb)).to eq(expected_flags)
        expect(sb.variant).to eq(expected_variant)
        expect(unit.variant).to eq(expected_variant) unless %i[draw non_strict_mismatch].include?(branch)
        expect([sb.id, sb.name, sb.exposed_at]).to eq([unit.id, unit.name, unit.exposed_at])
      end
    end

    # A traffic miss on an eligible cluster is recorded; an ineligible cluster records nothing.
    it "records a traffic miss on an eligible cluster as an ineligible exposure" do
      context = create_context([switchback(1, "exp_miss", 2, HOUR, trafficSplit: [1.0, 0.0]),
                                switchback(2, "exp_cluster_ineligible", 2, HOUR, trafficSplit: [1.0, 0.0],
                                                                                 switchbackClusterValues: ["other-store"])])
      clock.now = ANCHOR + 2 * HOUR + 3
      expect(context.treatment("exp_miss")).to eq(0)
      expect(context.treatment("exp_cluster_ineligible")).to eq(0)
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_miss", 0, ANCHOR + 2 * HOUR + 3, true, false)])
    end

    it "keeps custom field and unit lookups working" do
      context = create_context([switchback])
      expect(context.get_unit(UNIT_TYPE)).to eq(UID)
      expect(context.custom_field_keys).to eq([])
      expect(context.custom_field_value("exp_sb", "missing")).to be_nil
    end

    # Each experiment keeps slots for at most its two most recent periods.
    it "bounds the per-period cache" do
      context = create_context([switchback])
      50.times do |i|
        clock.now = ANCHOR + i * HOUR
        context.treatment("exp_sb")
      end
      expect(context.send(:assignment_cache).size).to eq(2)
      expect(context.pending_count).to eq(50)
    end

    it "never uses unitType to assign a switchback" do
      context = create_context([switchback(unitType: "user_id")], units: { UNIT_TYPE => UID, "user_id" => "u1" })
      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[i])
      end
      expect(published_exposures(context).map(&:unit)).to eq([UNIT_TYPE] * 3)
    end

    # The publish payload has no switchback-specific fields; the cluster attribute is published
    # with its timestamp, since the Collector re-resolves the cluster at exposedAt.
    it "adds no fields to the publish payload" do
      context = create_context([switchback])
      clock.now = ANCHOR + 5
      context.treatment("exp_sb")
      clock.now = ANCHOR + HOUR + 7
      context.treatment("exp_sb")
      clock.now = ANCHOR + HOUR + 9

      exposure_json = lambda do |variant, at|
        { "id" => 1, "name" => "exp_sb", "unit" => UNIT_TYPE, "exposedAt" => at, "variant" => variant,
          "assigned" => true, "eligible" => true, "overridden" => false, "fullOn" => false, "custom" => false,
          "audienceMismatch" => false, "ruleOverride" => false }
      end
      json = serialized_publish(context)
      expect(json).to eq(JSON.generate(
                           publishedAt: ANCHOR + HOUR + 9, units: [{ type: UNIT_TYPE, uid: UID_HASH }], hashed: true,
                           exposures: [exposure_json.call(EXPECTED_2_ARMS[0], ANCHOR + 5),
                                       exposure_json.call(EXPECTED_2_ARMS[1], ANCHOR + HOUR + 7)],
                           attributes: [{ name: CLUSTER_PATH, value: CLUSTER_KEY, setAt: ANCHOR }]
                         ))
      expect(EXPECTED_2_ARMS[0]).not_to eq(EXPECTED_2_ARMS[1])
    end

    it "keeps one exposure per period across flushes" do
      context = create_context([switchback])
      clock.now = ANCHOR
      context.treatment("exp_sb")
      context.publish
      clock.now = ANCHOR + 1
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(0)
      clock.now = ANCHOR + HOUR
      context.treatment("exp_sb")
      context.publish

      events = context.send(:event_handler).events
      expect(events.length).to eq(2)
      expect(events.flat_map(&:exposures).map(&:variant)).to eq([EXPECTED_2_ARMS[0], EXPECTED_2_ARMS[1]])
    end

    # The clock crosses into period 1 after the first read; the exposure keeps the instant that
    # selected period 0.
    it "stamps a treatment exposure with the resolution instant" do
      context = create_context([switchback])
      clock.now = ANCHOR + HOUR
      clock.next_read = ANCHOR + HOUR - 1

      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR + HOUR - 1,
                                                              true, true)])
    end

    it "stamps a variable exposure with the resolution instant" do
      # A holdout with all traffic in arm 1; holdouts never fire through a switchback.
      context = create_context([switchback(holdoutIds: [11])], holdouts: [holdout([0.0, 1.0])])
      clock.now = ANCHOR + HOUR
      clock.next_read = ANCHOR + HOUR - 1

      expect(context.variable_value("sb.arm", -1)).to eq(EXPECTED_2_ARMS[0])
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR + HOUR - 1,
                                                              true, true)])
    end

    # A peek caches the slot without exposing; the later treatment exposes at its own instant.
    it "stamps an exposure after a peek with the exposing call's instant" do
      context = create_context([switchback])
      clock.now = ANCHOR + 10
      expect(context.peek_treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      clock.now = ANCHOR + 20 * 60_000
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR + 20 * 60_000,
                                                              true, true)])
    end

    # A switchback elsewhere in the payload makes the call read the clock up front.
    it "keeps stamping unit experiments at enqueue time" do
      context = create_context([switchback(randomizationType: "unit"), switchback(2, "exp_other")])
      clock.now = ANCHOR + HOUR
      clock.next_read = ANCHOR + HOUR - 1

      variant = context.treatment("exp_sb")
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", variant, ANCHOR + HOUR, true, true)])
    end

    # A grid change that lowers the current index below the retained ones must not evict the slot
    # it just installed.
    it "exposes once after a grid refresh to a lower index" do
      context = create_context([switchback])
      clock.now = ANCHOR + 99 * HOUR
      context.treatment("exp_sb")
      clock.now = ANCHOR + 100 * HOUR
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(2)

      refresh_to(context, [switchback(switchbackStartAt: ANCHOR + 100 * HOUR)])
      3.times { expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0]) }
      expect(context.pending_count).to eq(3)
    end

    it "exposes once after a period length refresh to a lower index" do
      context = create_context([switchback])
      clock.now = ANCHOR + 100 * HOUR
      context.treatment("exp_sb")
      clock.now = ANCHOR + 101 * HOUR
      context.treatment("exp_sb")

      refresh_to(context, [switchback(1, "exp_sb", 2, 200 * HOUR)])
      2.times { context.treatment("exp_sb") }
      expect(context.pending_count).to eq(3)
    end

    # Rewinding the clock re-exposes each re-entered evicted period at most once.
    it "re-exposes an evicted period at most once after a clock rewind" do
      context = create_context([switchback])
      3.times do |i|
        clock.now = ANCHOR + i * HOUR
        context.treatment("exp_sb")
      end
      expect(context.pending_count).to eq(3)

      clock.now = ANCHOR
      3.times { expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0]) }
      expect(context.pending_count).to eq(4)

      # Retained {0, 2}: period 2 is still deduplicated, period 1 was evicted.
      clock.now = ANCHOR + 2 * HOUR
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(4)
      clock.now = ANCHOR + HOUR
      3.times { expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[1]) }
      expect(context.pending_count).to eq(5)

      exposures = published_exposures(context)
      expect(exposures[3]).to eq(sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[0], ANCHOR, true, true))
      expect(exposures[4]).to eq(sb_exposure(1, "exp_sb", EXPECTED_2_ARMS[1], ANCHOR + HOUR, true, true))
    end

    # An overridden slot is re-resolved on a grid change; the override still wins and the
    # holdout never fires.
    it "re-resolves an override when the grid changes" do
      context = create_context([switchback(1, "exp_sb", 3, HOUR, holdoutIds: [11])], holdouts: [holdout([0.0, 1.0])])
      context.set_override("exp_sb", 2)

      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(2)
      expect(context.variable_value("sb.arm", -1)).to eq(2)
      expect(context.pending_count).to eq(1)

      # Same index 0 under the new period length; variant 2 now carries a different value.
      regridded = switchback(1, "exp_sb", 3, 2 * HOUR, holdoutIds: [11])
      regridded[:variants][2] = { name: "C", config: '{"sb.arm":22}' }
      refresh_to(context, [regridded], [holdout([0.0, 1.0])])

      expect(context.treatment("exp_sb")).to eq(2)
      expect(context.variable_value("sb.arm", -1)).to eq(22)
      expect(context.pending_count).to eq(2)
      expect(published_exposures(context)).to eq(
        [exposure(1, "exp_sb", UNIT_TYPE, 2, ANCHOR + 10, false, true, true, false, false, false)] * 2
      )
    end

    # Each identity transition is a new epoch.
    it "re-resolves after switchback to unit to an identical switchback" do
      context = create_context([switchback])
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)

      refresh_to(context, [switchback(randomizationType: "unit")])
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(2)

      refresh_to(context, [switchback])
      2.times { expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0]) }
      expect(context.pending_count).to eq(3)
    end

    it "re-resolves a removed and restored switchback" do
      context = create_context([switchback])
      clock.now = ANCHOR + 10
      context.treatment("exp_sb")

      refresh_to(context, [])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(2)

      refresh_to(context, [switchback])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(3)
    end

    # The pre-anchor bare-name slot shares the lifecycle of the period slots.
    it "drops the pre-anchor slot when the grid changes" do
      grid_a = switchback(switchbackStartAt: ANCHOR + 10 * HOUR)
      context = create_context([grid_a])
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)

      refresh_to(context, [switchback])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(1)

      refresh_to(context, [grid_a])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(0)
      expect(context.pending_count).to eq(1)
    end

    # Epochs are reconciled lazily; an intermediate state never looked up still ends the epoch.
    it "re-resolves after transitions without an intervening lookup" do
      context = create_context([switchback])
      clock.now = ANCHOR + 10
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(1)

      refresh_to(context, [switchback(randomizationType: "unit")])
      refresh_to(context, [switchback])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(2)

      refresh_to(context, [])
      refresh_to(context, [switchback])
      expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0])
      expect(context.pending_count).to eq(3)

      refresh_to(context, [switchback(switchbackDesignType: "other")])
      refresh_to(context, [switchback])
      2.times { expect(context.treatment("exp_sb")).to eq(EXPECTED_2_ARMS[0]) }
      expect(context.pending_count).to eq(4)

      # An unchanged identity keeps the epoch.
      refresh_to(context, [switchback])
      context.treatment("exp_sb")
      expect(context.pending_count).to eq(4)
    end

    # Counts assignment-rule evaluations.
    class CountingAudienceMatcher < AudienceMatcher
      attr_accessor :rule_evaluations

      def initialize
        super(DefaultAudienceDeserializer.new)
        @rule_evaluations = 0
      end

      def evaluate_parsed_rules(*args)
        @rule_evaluations += 1
        super
      end
    end

    # A legacy switchback serves under its declared unitType, so a unitType change is identity.
    it "treats a unitType change on a legacy switchback as identity" do
      context = create_context([switchback(switchbackClusters: nil)], units: { UNIT_TYPE => UID, "user_id" => "u1" })
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(0)
      expect(context.send(:switchback_resolution_for_test, "exp_sb").unit_type).to eq(UNIT_TYPE)

      refresh_to(context, [switchback(switchbackClusters: nil, unitType: "other")])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(-1)

      refresh_to(context, [switchback(switchbackClusters: nil, unitType: "user_id")])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.variable_value("sb.arm", -1)).to eq(0)
      resolution = context.send(:switchback_resolution_for_test, "exp_sb")
      expect([resolution.unit_type, resolution.eligible, resolution.switchback_silent]).to eq(["user_id", false, true])
      expect(context.pending_count).to eq(0)
    end

    # An ineligible or absent slot never consulted its rules.
    it "never re-evaluates rules for an ineligible or absent slot" do
      matcher = CountingAudienceMatcher.new
      ineligible = switchback(1, "exp_ineligible", 2, HOUR, assignmentRules: ASSIGN_VARIANT_1,
                                                            switchbackClusterValues: ["other-store"])
      absent = switchback(2, "exp_absent", 2, HOUR, assignmentRules: ASSIGN_VARIANT_1,
                                                    switchbackClusters: { "device_id" => CLUSTER_PATH })
      context = create_context([ineligible, absent], audience_matcher: matcher)
      clock.now = ANCHOR + 10
      expect(context.treatment("exp_ineligible")).to eq(0)
      expect(context.treatment("exp_absent")).to eq(0)
      expect(matcher.rule_evaluations).to eq(0)

      context.set_attribute("x", 1)
      changed = '{"rules":[{"type":"assign","environments":[],"variant":1,"name":"changed"}]}'
      refresh_to(context, [ineligible.merge(assignmentRules: changed), absent.merge(assignmentRules: changed)])

      expect(context.treatment("exp_ineligible")).to eq(0)
      expect(context.treatment("exp_absent")).to eq(0)
      expect(matcher.rule_evaluations).to eq(0)
      expect(context.pending_count).to eq(0)
    end

    # Rules are not switchback identity: no second exposure in the period.
    it "keeps the variant and exposes once on an in-period rule refresh" do
      context = create_context([switchback(assignmentRules: ASSIGN_VARIANT_1)])
      clock.now = ANCHOR + 5
      expect(context.treatment("exp_sb")).to eq(1)

      context.set_attribute("tier", "x")
      refreshed = '{"rules":[{"type":"assign","environments":[],"variant":1,' \
                  '"conditions":{"and":[{"eq":[{"var":"tier"},{"value":"x"}]}]}}]}'
      refresh_to(context, [switchback(assignmentRules: refreshed)])
      clock.now = ANCHOR + 6
      expect(context.treatment("exp_sb")).to eq(1)
      expect(published_exposures(context)).to eq([rule_exposure("exp_sb", 1, ANCHOR + 5)])
    end

    # SDK choice: before the anchor nothing is recorded, a traffic miss included. From the anchor
    # the same miss is recorded.
    it "keeps a pre-anchor traffic miss silent" do
      clock.now = ANCHOR - 1
      context = create_context([switchback(trafficSplit: [1.0, 0.0])])
      expect(context.treatment("exp_sb")).to eq(0)
      expect(context.pending_count).to eq(0)

      clock.now = ANCHOR
      expect(context.treatment("exp_sb")).to eq(0)
      expect(published_exposures(context)).to eq([sb_exposure(1, "exp_sb", 0, ANCHOR, true, false)])
    end

    # An override with no serving unit is exposed under the declared unitType on the legacy path.
    it "exposes an override on a legacy switchback under the declared unitType" do
      context = create_context([switchback(1, "exp_missing_map", 2, HOUR, unitType: "user_id", switchbackClusters: nil),
                                switchback(2, "exp_unreadable_map", 2, HOUR, unitType: "user_id",
                                                                             switchbackClusters: { UNIT_TYPE => "'unterminated" })],
                               overrides: { "exp_missing_map" => 1, "exp_unreadable_map" => 1 })
      clock.now = ANCHOR + 5
      expect(context.treatment("exp_missing_map")).to eq(1)
      expect(context.treatment("exp_unreadable_map")).to eq(1)

      expect(published_exposures(context)).to eq([
        exposure(1, "exp_missing_map", "user_id", 1, ANCHOR + 5, false, true, true, false, false, false),
        exposure(2, "exp_unreadable_map", "user_id", 1, ANCHOR + 5, false, true, true, false, false, false)
      ])
    end

    it "serializes a rule-won and a traffic-miss exposure exactly" do
      context = create_context([switchback(1, "exp_rule", 2, HOUR, assignmentRules: ASSIGN_VARIANT_1),
                                switchback(2, "exp_miss", 2, HOUR, trafficSplit: [1.0, 0.0])])
      clock.now = ANCHOR + 5
      context.treatment("exp_rule")
      context.treatment("exp_miss")
      clock.now = ANCHOR + 9

      flags = lambda do |assigned, eligible, rule|
        { "assigned" => assigned, "eligible" => eligible, "overridden" => false, "fullOn" => false,
          "custom" => false, "audienceMismatch" => false, "ruleOverride" => rule }
      end
      expect(JSON.parse(serialized_publish(context))).to eq(
        "publishedAt" => ANCHOR + 9, "units" => [{ "type" => UNIT_TYPE, "uid" => UID_HASH }], "hashed" => true,
        "exposures" => [
          { "id" => 1, "name" => "exp_rule", "unit" => UNIT_TYPE, "exposedAt" => ANCHOR + 5, "variant" => 1 }
            .merge(flags.call(false, true, true)),
          { "id" => 2, "name" => "exp_miss", "unit" => UNIT_TYPE, "exposedAt" => ANCHOR + 5, "variant" => 0 }
            .merge(flags.call(true, false, false))
        ],
        "attributes" => [{ "name" => CLUSTER_PATH, "value" => CLUSTER_KEY, "setAt" => ANCHOR }]
      )
    end

    # Audience evaluation runs under the assignment lock; refreshing from inside it must not deadlock.
    class RefreshingAudienceMatcher < AudienceMatcher
      attr_accessor :context, :refresh_next

      def initialize
        super(DefaultAudienceDeserializer.new)
      end

      def evaluate(_audience, _attributes)
        if @refresh_next
          @refresh_next = false
          context.refresh
        end
        AudienceMatcher::Result.new(true)
      end
    end

    it "does not deadlock when audience evaluation refreshes the context" do
      matcher = RefreshingAudienceMatcher.new
      experiment = switchback(audience: '{"filter":[{"value":true}]}')
      context = create_context([experiment], audience_matcher: matcher)
      matcher.context = context
      allow(provider).to receive(:context_data).and_return(ready(data_of([experiment])))

      primed = context.treatment("exp_sb")
      context.set_attribute("country", "PT")
      matcher.refresh_next = true
      worker = Thread.new { context.treatment("exp_sb") }
      expect(worker.join(10)).not_to be_nil
      expect(worker.value).to eq(primed)
      expect(provider).to have_received(:context_data).once
      expect(context.pending_count).to eq(1)
    end

    it "exposes once when many threads resolve the same period" do
      context = create_context([switchback])
      clock.now = ANCHOR + HOUR + 10
      threads = Array.new(8) { Thread.new { 50.times.map { context.treatment("exp_sb") } } }
      expect(threads.flat_map(&:value).uniq).to eq([EXPECTED_2_ARMS[1]])
      expect(context.pending_count).to eq(1)
    end
  end
end

# No cost without switchbacks: a payload without one never reads the clock on
# treatment, peek or variable reads, and builds no switchback state.
module ContextSwitchbackCostSpec
  RSpec.describe "Context without switchbacks" do
    include SwitchbackSpecSupport

    let(:clock) { SwitchbackSpecSupport::MutableClock.new(SwitchbackSpecSupport::ANCHOR) }

    it "reads no clock on the assignment paths" do
      json = File.read(File.join(__dir__, "fixtures", "resources", "context.json"))
      data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
      context = build_context(data, units: { session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec", user_id: "1" })
      context.peek_treatment("exp_test_ab")
      allow(clock).to receive(:call).and_call_original
      context.treatment("exp_test_ab")
      context.peek_treatment("exp_test_ab")
      context.variable_value("banner.border", 0)
      context.peek_variable_value("banner.border", 0)
      # Only the exposure itself reads the clock, once.
      expect(clock).to have_received(:call).once
      expect(context.instance_variable_get(:@switchback_epochs)).to be_empty
    end
  end
end
