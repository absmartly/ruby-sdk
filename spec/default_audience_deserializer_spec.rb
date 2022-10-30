# frozen_string_literal: true

require "default_audience_deserializer"
require "context"
require "client"
require "json/publish_event"
require "byebug"

RSpec.describe DefaultAudienceDeserializer do
  it ".deserialize" do
    deser = described_class.new
    audience = "{\"filter\":[{\"gte\":[{\"var\":\"age\"},{\"value\":20}]}]}"

    expected = { "filter": [{ "gte": [{ "var": "age" }, { "value": 20 }] }] }
    actual = deser.deserialize(audience, 0, audience.length)
    expect(actual).to eq(expected)
  end

  it ".deserialize does not throw" do
    deser = described_class.new
    audience = "{\"filter\":[{\"gte\":[{\"var\":\"age\"},{\"value\":20}]}]}"
    expect(deser.deserialize(audience, 0, 14)).to be_nil
  end
end
