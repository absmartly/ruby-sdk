# frozen_string_literal: true

require "context_config"
require "context_data_deserializer"
require "context_event_serializer"

RSpec.describe ContextConfig do
  it ".set_unit" do
    config = described_class.create
    config.set_unit("session_id", "0ab1e23f4eee")
    expect(config.unit("session_id")).to eq("0ab1e23f4eee")
  end

  it ".set_attribute" do
    config = described_class.create
                            .set_attribute("user_agent", "Chrome")
                            .set_attribute("age", 9)
    expect(config.attribute("user_agent")).to eq("Chrome")
    expect(config.attribute("age")).to eq(9)
  end

  it ".set_attributes" do
    attributes = { "user_agent": "Chrome", "age": 9 }
    config = described_class.create
                            .set_attributes(attributes)
    expect(config.attribute("user_agent")).to eq("Chrome")
    expect(config.attribute("age")).to eq(9)
    expect(config.attributes).to eq(attributes)
  end

  it ".set_attributes merges with set_attribute" do
    config = described_class.create
                            .set_attribute("attr1", "value1")
                            .set_attributes({ attr2: "value2", attr3: 15 })

    expect(config.attribute("attr1")).to eq("value1")
    expect(config.attribute("attr2")).to eq("value2")
    expect(config.attribute("attr3")).to eq(15)
  end

  it ".set_attributes can be called multiple times" do
    config = described_class.create
                            .set_attributes({ attr1: "value1" })
                            .set_attributes({ attr2: "value2" })

    expect(config.attribute("attr1")).to eq("value1")
    expect(config.attribute("attr2")).to eq("value2")
  end

  it ".set_override" do
    config = described_class.create
                            .set_override("exp_test", 2)
    expect(config.override("exp_test")).to eq(2)
  end

  it ".set_overrides" do
    overrides = { "exp_test": 2, "exp_test_new": 1 }
    config = described_class.create
    config.overrides = overrides
    expect(config.override("exp_test")).to eq(2)
    expect(config.override("exp_test_new")).to eq(1)
    expect(config.overrides).to eq(overrides)
  end

  it ".set_custom_assignment" do
    config = described_class.create
                            .set_custom_assignment("exp_test", 2)
    expect(config.custom_assignment("exp_test")).to eq(2)
  end

  it ".set_custom_assignments" do
    custom_assignments = { "exp_test": 2, "exp_test_new": 1 }
    config = described_class.create
    config.custom_assignments = custom_assignments
    expect(config.custom_assignment("exp_test")).to eq(2)
    expect(config.custom_assignment("exp_test_new")).to eq(1)
    expect(config.custom_assignments).to eq(custom_assignments)
  end

  it ".publish_delay" do
    config = described_class.create
    config.publish_delay = 999
    expect(config.publish_delay).to eq(999)
  end

  it ".refresh_interval" do
    config = described_class.create
    config.refresh_interval = 999
    expect(config.refresh_interval).to eq(999)
  end
end
