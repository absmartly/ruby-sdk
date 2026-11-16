# frozen_string_literal: true

require "default_context_data_deserializer"
require "context"
require "client"
require "json/context_data"
require "json/publish_event"
require "json/experiment"
require "json/experiment_application"
require "json/experiment_variant"

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
    experiment0.custom_field_values = [
      CustomFieldValue.new("country", "US,PT,ES,DE,FR", "string"),
      CustomFieldValue.new("overrides", "{\"123\":1,\"456\":0}", "json"),
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
    experiment1.custom_field_values = [
      CustomFieldValue.new("country", "US,PT,ES,DE,FR", "string"),
      CustomFieldValue.new("languages", "en-US,en-GB,pt-PT,pt-BR,es-ES,es-MX", "string"),
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

  it ".deserialize reads assignmentRules as a JSON string" do
    rules = JSON.generate(rules: [{ type: "assign", variant: 1 }])
    json = JSON.generate(experiments: [{ id: 1, name: "exp", unitType: "session_id", assignmentRules: rules,
                                         variants: [{ name: "A", config: nil }] }])
    data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)

    expect(data.experiments.first.assignment_rules).to eq(rules)
  end

  it ".deserialize leaves assignmentRules nil when absent" do
    json = JSON.generate(experiments: [{ id: 1, name: "exp", unitType: "session_id", variants: [] }])
    data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)

    expect(data.experiments.first.assignment_rules).to be_nil
  end

  describe "forward compatibility" do
    def decode(raw)
      json = JSON.generate(raw)
      described_class.new.deserialize(json, 0, json.length)
    end

    def experiment(**overrides)
      { id: 1, name: "exp", unitType: "session_id", iteration: 1, seedHi: 1, seedLo: 2, split: [0.5, 0.5],
        trafficSeedHi: 3, trafficSeedLo: 4, trafficSplit: [0.0, 1.0], fullOnVariant: 0,
        applications: [{ name: "website" }],
        variants: [{ name: "A", config: nil }, { name: "B", config: "{\"a\":1}" }],
        audienceStrict: false, audience: "",
        customFieldValues: [{ name: "f", value: "v", type: "string" }] }.merge(overrides)
    end

    it "ignores unknown keys at the root and experiment level" do
      data = decode(experiments: [experiment(newField: 1)], newRoot: { x: 1 })
      expect(data.experiments.first.name).to eq("exp")
    end

    it "ignores unknown keys in variants, applications and custom field values" do
      data = decode(experiments: [
        experiment(variants: [{ name: "A", config: nil, extra: 1 }, { name: "B", config: "{}", id: 7 }],
                   applications: [{ name: "website", id: 3 }],
                   customFieldValues: [{ name: "f", value: "v", type: "string", sortOrder: 1 }]),
        experiment(id: 2, name: "other")
      ])

      expect(data).not_to be_nil
      expect(data.experiments.map(&:name)).to eq(%w[exp other])
      first = data.experiments.first
      expect(first.variants).to eq([ExperimentVariant.new("A", nil), ExperimentVariant.new("B", "{}")])
      expect(first.applications).to eq([ExperimentApplication.new("website")])
      expect(first.custom_field_values).to eq([CustomFieldValue.new("f", "v", "string")])
    end

    it "reads nested objects by key, whatever the property order" do
      data = decode(experiments: [
        experiment(variants: [{ config: "{\"a\":1}", name: "A" }],
                   customFieldValues: [{ type: "json", value: "{}", name: "f" }])
      ])

      first = data.experiments.first
      expect(first.variants.first.name).to eq("A")
      expect(first.variants.first.config).to eq("{\"a\":1}")
      expect([first.custom_field_values.first.name, first.custom_field_values.first.type])
        .to eq(%w[f json])
    end

    it "leaves missing optional nested fields nil" do
      data = decode(experiments: [experiment(variants: [{ name: "A" }], applications: [{}],
                                             customFieldValues: [{ name: "f" }])])

      first = data.experiments.first
      expect(first.variants.first.config).to be_nil
      expect(first.applications.first.name).to be_nil
      expect(first.custom_field_values.first.value).to be_nil
    end

    it "keeps the context usable with unknown nested keys" do
      raw = JSON.parse(resource("context.json"))
      raw["experiments"].each do |e|
        e["variants"].each { |v| v["futureField"] = { "nested" => true } }
        e["applications"].each { |a| a["futureField"] = 1 }
        (e["customFieldValues"] || []).each { |c| c["futureField"] = 1 }
      end
      data = decode(raw)
      plain = described_class.new.deserialize(resource("context.json"), 0, resource("context.json").length)

      expect(data).to eq(plain)
    end
  end
end
