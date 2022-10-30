# frozen_string_literal: true

require "default_context_data_deserializer"
require "context"
require "client"
require "json/context_data"
require "json/publish_event"
require "json/experiment"
require "json/experiment_application"
require "json/experiment_variant"
require "byebug"

RSpec.describe DefaultContextDataDeserializer do
  it ".deserialize" do
    string = resource("context.json")
    deser = described_class.new
    data = deser.deserialize(string, 0, string.length)

    experiment0 = Experiment.new
    experiment0.id = 1
    experiment0.name = "exp_test_ab"
    experiment0.unit_type = "session_id"
    experiment0.iteration = 1
    experiment0.seed_hi = 3603515
    experiment0.seed_lo = 233373850
    experiment0.split = [0.5, 0.5]
    experiment0.traffic_seed_hi = 449867249
    experiment0.traffic_seed_lo = 455443629
    experiment0.traffic_split = [0.0, 1.0]
    experiment0.full_on_variant = 0
    experiment0.applications = [ExperimentApplication.new("website")]
    experiment0.variants = [
      ExperimentVariant.new("A", nil),
      ExperimentVariant.new("B", "{\"banner.border\":1,\"banner.size\":\"large\"}")
    ]
    experiment0.audience_strict = false
    experiment0.audience = nil

    experiment1 = Experiment.new
    experiment1.id = 2
    experiment1.name = "exp_test_abc"
    experiment1.unit_type = "session_id"
    experiment1.iteration = 1
    experiment1.seed_hi = 55006150
    experiment1.seed_lo = 47189152
    experiment1.split = [0.34, 0.33, 0.33]
    experiment1.traffic_seed_hi = 705671872
    experiment1.traffic_seed_lo = 212903484
    experiment1.traffic_split = [0.0, 1.0]
    experiment1.full_on_variant = 0
    experiment1.applications = [ExperimentApplication.new("website")]
    experiment1.variants = [
      ExperimentVariant.new("A", nil),
      ExperimentVariant.new("B", "{\"button.color\":\"blue\"}"),
      ExperimentVariant.new("C", "{\"button.color\":\"red\"}")
    ]
    experiment1.audience_strict = false
    experiment1.audience = ""

    experiment2 = Experiment.new
    experiment2.id = 3
    experiment2.name = "exp_test_not_eligible"
    experiment2.unit_type = "user_id"
    experiment2.iteration = 1
    experiment2.seed_hi = 503266407
    experiment2.seed_lo = 144942754
    experiment2.split = [0.34, 0.33, 0.33]
    experiment2.traffic_seed_hi = 87768905
    experiment2.traffic_seed_lo = 511357582
    experiment2.traffic_split = [0.99, 0.01]
    experiment2.full_on_variant = 0
    experiment2.applications = [ExperimentApplication.new("website")]
    experiment2.variants = [
      ExperimentVariant.new("A", nil),
      ExperimentVariant.new("B", "{\"card.width\":\"80%\"}"),
      ExperimentVariant.new("C", "{\"card.width\":\"75%\"}")
    ]
    experiment2.audience_strict = false
    experiment2.audience = "{}"

    experiment3 = Experiment.new
    experiment3.id = 4
    experiment3.name = "exp_test_fullon"
    experiment3.unit_type = "session_id"
    experiment3.iteration = 1
    experiment3.seed_hi = 856061641
    experiment3.seed_lo = 990838475
    experiment3.split = [0.25, 0.25, 0.25, 0.25]
    experiment3.traffic_seed_hi = 360868579
    experiment3.traffic_seed_lo = 330937933
    experiment3.traffic_split = [0.0, 1.0]
    experiment3.full_on_variant = 2
    experiment3.applications = [ExperimentApplication.new("website")]
    experiment3.variants = [
      ExperimentVariant.new("A", nil),
      ExperimentVariant.new("B", "{\"submit.color\":\"red\",\"submit.shape\":\"circle\"}"),
      ExperimentVariant.new("C", "{\"submit.color\":\"blue\",\"submit.shape\":\"rect\"}"),
      ExperimentVariant.new("D", "{\"submit.color\":\"green\",\"submit.shape\":\"square\"}")
    ]
    experiment3.audience_strict = false
    experiment3.audience = "null"

    expected = ContextData.new
    expected.experiments = [
      experiment0,
      experiment1,
      experiment2,
      experiment3
    ]

    expect(data).not_to be_nil
    expect(data).to eq(expected)
  end

  it ".deserialize does not throw" do
    string = resource("context.json")

    deser = described_class.new
    expect(deser.deserialize(string, 0, 14)).to be_nil
  end
end
