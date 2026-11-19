# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "client"
require "context_config"
require "json/context_data"
require "context_data_result"
require "audience_matcher"
require "default_context_data_deserializer"
require "default_variable_parser"
require "switchback_support"
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

  it "stamps in live milliseconds through every context factory" do
    allow(Process).to receive(:clock_gettime).and_call_original
    readings = (1..9).map { |i| 1_767_225_600_000 + i }
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_REALTIME, :millisecond) { readings.shift }
    absmartly = ABSmartly.create(ABSmartlyConfig.create.tap { |config| config.client = client })
    context_config = ContextConfig.create
    context_config.set_unit(:session_id, "abc")
    contexts = [absmartly.create_context_with(context_config, ContextDataResult.new(ContextData.new([]))),
                absmartly.create_context_async(context_config).wait_until_ready(5)]
    contexts.each do |context|
      context.track("goal")
      context.publish
    end

    expect(published.map { |event| event.goals.first.achieved_at }).to eq([1_767_225_600_001, 1_767_225_600_003])
    expect(published.map(&:published_at)).to eq([1_767_225_600_002, 1_767_225_600_004])
  end

  # The Collector rejects a batch with an event after publishedAt, so a clock that stepped back
  # between an event and the publish must not get the batch rejected; the events keep their stamps.
  it "publishes no earlier than its latest event after the clock steps back" do
    allow(Process).to receive(:clock_gettime).and_call_original
    readings = [1_767_225_600_010, 1_767_225_600_012, 1_767_225_600_005]
    allow(Process).to receive(:clock_gettime).with(Process::CLOCK_REALTIME, :millisecond) { readings.shift }
    context = create_context
    context.track("goal")
    context.track("goal")
    context.publish

    event = published.first
    expect(event.goals.map(&:achieved_at)).to eq([1_767_225_600_010, 1_767_225_600_012])
    expect(event.published_at).to eq(1_767_225_600_012)
  end

  it "publishes no earlier than a queued exposure after the clock steps back" do
    clock = SwitchbackSpecSupport::MutableClock.new(1_767_225_600_050)
    json = File.read(File.join(__dir__, "fixtures", "resources", "context.json"))
    data = DefaultContextDataDeserializer.new.deserialize(json, 0, json.length)
    config = ContextConfig.create
    config.set_unit(:session_id, "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
    publisher = SwitchbackSpecSupport::Publisher.new
    context = Context.create(clock, config, ContextDataResult.new(data), nil, publisher, nil,
                             DefaultVariableParser.new, AudienceMatcher.new(DefaultAudienceDeserializer.new))
    context.treatment("exp_test_ab")
    clock.now = 1_767_225_600_010
    context.publish

    event = publisher.events.first
    expect(event.exposures.map(&:exposed_at)).to eq([1_767_225_600_050])
    expect(event.published_at).to eq(1_767_225_600_050)
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
