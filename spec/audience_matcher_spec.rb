# frozen_string_literal: true

require "audience_matcher"
require "default_audience_deserializer"

RSpec.describe AudienceMatcher do
  let(:matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }

  it "evaluate returns nil on empty audience" do
    expect(matcher.evaluate("", nil)).to be_nil
    expect(matcher.evaluate("{}", nil)).to be_nil
    expect(matcher.evaluate("nil", nil)).to be_nil
  end

  it "evaluate returns nil if filter not map or list" do
    expect(matcher.evaluate("{\"filter\":nil}", nil)).to be_nil
    expect(matcher.evaluate("{\"filter\":false}", nil)).to be_nil
    expect(matcher.evaluate("{\"filter\":5}", nil)).to be_nil
    expect(matcher.evaluate("{\"filter\":\"a\"}", nil)).to be_nil
  end

  it "evaluate returns boolean" do
    expect(matcher.evaluate("{\"filter\":[{\"value\":5}]}", nil).get).to be_truthy
    expect(matcher.evaluate("{\"filter\":[{\"value\":true}]}", nil).get).to be_truthy
    expect(matcher.evaluate("{\"filter\":[{\"value\":1}]}", nil).get).to be_truthy
    expect(matcher.evaluate("{\"filter\":[{\"value\":null}]}", nil).get).to be_falsey
    expect(matcher.evaluate("{\"filter\":[{\"value\":0}]}", nil).get).to be_falsey

    expect(
      matcher.evaluate("{\"filter\":[{\"not\":{\"var\":\"returning\"}}]}", { returning: true }).get).to be_falsey
    expect(
      matcher.evaluate("{\"filter\":[{\"not\":{\"var\":\"returning\"}}]}", { returning: false }).get).to be_truthy
  end
end
