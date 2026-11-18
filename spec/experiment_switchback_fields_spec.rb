# frozen_string_literal: true

require "json"
require "default_context_data_deserializer"
require "json/experiment"

# Ports of java-sdk ExperimentSwitchbackFieldsTest and the switchback cases of
# DefaultContextDataDeserializerTest.
RSpec.describe "Experiment switchback fields" do
  def switchback(**overrides)
    Experiment.new({
      id: 1, name: "exp", unitType: "store_id", randomizationType: "switchback",
      switchbackClusters: { store_id: "store/key", device_id: "geo/city" },
      switchbackClusterValues: %w[porto lisbon], switchbackStartAt: 1_767_225_600_000,
      switchbackPeriodMs: 3_600_000, switchbackCarryoverDurationMs: 900_000, switchbackBurnInDurationMs: 600_000,
      switchbackBurnOutDurationMs: 0, switchbackDesignType: "balanced_block",
      switchbackEstimand: "global_average_treatment_effect"
    }.merge(overrides))
  end

  it "compares every switchback field, and the cluster order" do
    expect(switchback).to eq(switchback)
    [
      { randomizationType: "unit" },
      { switchbackClusters: nil },
      { switchbackClusters: { store_id: "store/key" } },
      { switchbackClusters: { store_id: "store/key", device_id: "geo/country" } },
      # Same entries, other order: the order is semantic.
      { switchbackClusters: { device_id: "geo/city", store_id: "store/key" } },
      { switchbackClusterValues: nil },
      { switchbackClusterValues: %w[lisbon porto] },
      { switchbackStartAt: 1_767_229_200_000 },
      { switchbackPeriodMs: 86_400_000 },
      { switchbackCarryoverDurationMs: nil },
      { switchbackBurnInDurationMs: 1 },
      { switchbackBurnOutDurationMs: 1 },
      { switchbackDesignType: "other" },
      { switchbackEstimand: "other" }
    ].each do |mutation|
      changed = switchback(**mutation)
      expect(changed).not_to eq(switchback), mutation.inspect
      expect(switchback).not_to eq(changed), mutation.inspect
    end
  end

  it "reads camelCase and snake_case keys alike" do
    snake = Experiment.new(id: 1, name: "exp", unit_type: "store_id", randomization_type: "switchback",
                           switchback_clusters: { "store_id" => "store/key", "device_id" => "geo/city" },
                           switchback_cluster_values: %w[porto lisbon], switchback_start_at: 1_767_225_600_000,
                           switchback_period_ms: 3_600_000, switchback_carryover_duration_ms: 900_000,
                           switchback_burn_in_duration_ms: 600_000, switchback_burn_out_duration_ms: 0,
                           switchback_design_type: "balanced_block",
                           switchback_estimand: "global_average_treatment_effect")
    expect(snake).to eq(switchback)
  end

  def deserialize(json)
    DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
  end

  it "deserializes every switchback field and ignores the Phase 1E and unknown ones" do
    data = deserialize(resource("switchback_context.json"))
    sb, unit = data.experiments

    expect([sb.randomization_type, sb.switchback_cluster_values, sb.switchback_start_at, sb.switchback_period_ms,
            sb.switchback_carryover_duration_ms, sb.switchback_burn_in_duration_ms, sb.switchback_burn_out_duration_ms,
            sb.switchback_design_type, sb.switchback_estimand])
      .to eq(["switchback", %w[porto lisbon], 1_767_225_600_000, 3_600_000, 900_000, 600_000, 0, "balanced_block",
              "global_average_treatment_effect"])
    # The declared order survives deserialization; it is not sorted.
    expect(sb.switchback_clusters.to_a).to eq([[:store_id, "store/key"], [:device_id, "geo/city"]])
    %i[@switchback_cluster_count @switchback_cluster_attribute @switchback_cluster_unit_type
       @switchback_future_field].each do |ivar|
      expect(sb.instance_variable_defined?(ivar)).to be(false), ivar.to_s
    end
    expect([unit.randomization_type, unit.switchback_start_at, unit.switchback_clusters]).to eq(["unit", nil, nil])
  end

  it "keeps the cluster order of the payload" do
    json = '{"experiments":[{"id":1,"name":"exp","randomizationType":"switchback",' \
           '"switchbackClusters":{"z_type":"a","a_type":"b","m_type":"c"}}]}'
    experiment = deserialize(json).experiments[0]
    expect(experiment.switchback_clusters.keys).to eq(%i[z_type a_type m_type])
    expect(experiment.switchback_cluster_values).to be_nil
  end

  it "leaves the switchback fields nil without them" do
    deserialize(resource("context.json")).experiments.each do |experiment|
      expect(experiment.switchback_fields).to all(be_nil)
    end
  end
end
