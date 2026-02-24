# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"

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
end
