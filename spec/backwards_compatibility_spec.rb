# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "context_event_handler"
require "json/experiment"

RSpec.describe "Backwards Compatibility" do
  it "SDK is an alias for ABSmartly" do
    expect(SDK).to eq(ABSmartly)
  end

  it "SDKConfig is an alias for ABSmartlyConfig" do
    expect(SDKConfig).to eq(ABSmartlyConfig)
  end

  it "can create SDK instance using the alias" do
    config = SDKConfig.create
    config.client = instance_double(Client)
    sdk = SDK.create(config)
    expect(sdk).to be_instance_of(ABSmartly)
  end

  it "ContextEventHandler is a deprecated alias for ContextPublisher" do
    original = Warning[:deprecated]
    Warning[:deprecated] = true
    expect { expect(Object.const_get(:ContextEventHandler)).to eq(ContextPublisher) }
      .to output(/ContextEventHandler is deprecated/).to_stderr
  ensure
    Warning[:deprecated] = original
  end

  it "converts experiment collections for every supported key form" do
    applications = [{ name: "website" }]
    variants = [{ name: "A", config: nil }]
    fields = [{ name: "country", value: "US", type: "string" }]
    [
      { applications: applications, variants: variants, customFieldValues: fields },
      { "applications" => applications, "variants" => variants, "custom_field_values" => fields }
    ].each do |args|
      experiment = Experiment.new(args)
      expect(experiment.applications.first).to be_a(ExperimentApplication)
      expect(experiment.variants.first).to be_a(ExperimentVariant)
      expect(experiment.custom_field_values.first).to be_a(CustomFieldValue)
    end
  end
end
