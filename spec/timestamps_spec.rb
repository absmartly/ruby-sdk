# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "client"
require "context_config"
require "json/context_data"
require "context_data_result"
require "audience_matcher"
require "default_audience_deserializer"

# The Collector reads every timestamp as epoch milliseconds, and a context's
# timestamps follow the wall clock, as in the JavaScript and Java SDKs.
RSpec.describe "Context timestamps" do
  let(:published) { [] }
  let(:client) do
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(ContextDataResult.new(ContextData.new([])))
    allow(client).to receive(:publish) { |event| published << event; OpenStruct.new(success?: true) }
    client
  end

  def create_context
    config = ABSmartlyConfig.create
    config.client = client
    context_config = ContextConfig.create
    context_config.set_unit(:session_id, "abc")
    ABSmartly.create(config).create_context(context_config)
  end

  it "stamps attributes, goals and the publish in live epoch milliseconds" do
    allow(Process).to receive(:clock_gettime).and_call_original
    readings = [1_767_225_600_123, 1_767_225_600_456, 1_767_225_601_789]
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_REALTIME, :millisecond) { readings.shift }
    context = create_context
    context.set_attribute("a", 1)
    context.track("goal")
    context.publish

    event = published.first
    expect(event.attributes.map(&:set_at)).to eq([1_767_225_600_123])
    expect(event.goals.map(&:achieved_at)).to eq([1_767_225_600_456])
    expect(event.published_at).to eq(1_767_225_601_789)
  end

  it "reads the real wall clock in milliseconds" do
    before = (Time.now.to_r * 1000).floor
    context = create_context
    context.track("goal")
    context.publish
    after = (Time.now.to_r * 1000).ceil

    expect(published.first.published_at).to be_between(before, after)
    expect(published.first.goals.first.achieved_at).to be_between(before, after)
  end

  it "keeps a fixed Time as one instant, in milliseconds" do
    context = Context.create(Time.at(1_620_000_000, 250, :millisecond), ContextConfig.create,
                             ContextDataResult.new(ContextData.new([])), nil, nil, nil, nil,
                             AudienceMatcher.new(DefaultAudienceDeserializer.new))
    context.set_attribute("a", 1)
    sleep 0.01
    context.set_attribute("b", 2)
    expect(context.send(:attributes).map(&:set_at)).to eq([1_620_000_000_250, 1_620_000_000_250])
  end
end
