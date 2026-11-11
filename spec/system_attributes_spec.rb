# frozen_string_literal: true

require "context"
require "context_config"
require "a_b_smartly"
require "a_b_smartly_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "default_context_data_provider"
require "client"
require "audience_matcher"
require "json/unit"
require "json/attribute"
require "json/publish_event"
require "default_context_event_serializer"

# The SDK seeds the audience evaluation map with the client's `application`
# and `environment` names (always on, no opt-out), so audience filters can
# target them even though the unit never set them. User-set attributes overlay
# the system values, empty values are skipped, and nothing extra is published
# (the collector adds application/environment server-side). `app_version` is
# never injected.
RSpec.describe "Context system attributes" do
  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:clock_in_millis) { clock.to_i }

  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("system_attributes_context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }

  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }

  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:event_handler) do
    ev = double("ContextPublisher")
    allow(ev).to receive(:publish).and_return(publish_future)
    ev
  end
  let(:event_logger) { nil }

  let(:units) { { session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec" } }

  def data_future(ctx_data = data)
    OpenStruct.new(data_future: ctx_data, success?: true)
  end

  def data_provider(ctx_data = data)
    DefaultContextDataProvider.new(
      instance_double(Client,
                      context_data: OpenStruct.new(data_future: ctx_data, success?: true))
    )
  end

  def create_context(application: "website", environment: "production", attributes: nil)
    config = ContextConfig.create
    config.set_units(units)
    config.set_attributes(attributes) unless attributes.nil?

    Context.create(clock, config, data_future, data_provider,
                   event_handler, event_logger, variable_parser, audience_matcher,
                   application: application, environment: environment)
  end

  # Test 1: strict audience on environment matches -> randomised (variant 1).
  it "matches a strict audience filtering on the configured environment" do
    context = create_context(environment: "production")

    assignment = context.peek_treatment("exp_env")
    expect(assignment).to eq(1)
  end

  it "reports no audience mismatch when the environment filter matches" do
    context = create_context(environment: "production")
    context.treatment("exp_env")

    expect(event_handler).to receive(:publish) do |_ctx, event|
      exposure = event.exposures.find { |e| e.name == "exp_env" }
      expect(exposure.audience_mismatch).to eq(false)
      expect(exposure.variant).to eq(1)
      publish_future
    end
    context.publish
  end

  # Test 2: strict audience on application matches.
  it "matches a strict audience filtering on the configured application" do
    context = create_context(application: "website")

    expect(context.peek_treatment("exp_app")).to eq(1)
  end

  # Test 3: no match -> control (variant 0), audienceMismatch true.
  it "serves control when the environment filter does not match" do
    context = create_context(environment: "staging")

    expect(context.peek_treatment("exp_env")).to eq(0)
  end

  it "reports an audience mismatch when the environment filter does not match" do
    context = create_context(environment: "staging")
    context.treatment("exp_env")

    expect(event_handler).to receive(:publish) do |_ctx, event|
      exposure = event.exposures.find { |e| e.name == "exp_env" }
      expect(exposure.audience_mismatch).to eq(true)
      expect(exposure.variant).to eq(0)
      publish_future
    end
    context.publish
  end

  # Test 4: user value overrides the system value, set after creation, and
  # invalidates a cached assignment.
  it "lets a user attribute set after creation override the system environment" do
    context = create_context(environment: "production")

    # Cache an assignment that matches the production system value.
    expect(context.peek_treatment("exp_env")).to eq(1)

    # Overriding environment to staging flips the strict audience to a mismatch
    # and invalidates the cached assignment.
    context.set_attribute("environment", "staging")
    expect(context.peek_treatment("exp_env")).to eq(0)
  end

  it "lets a user attribute make a non-matching system value match" do
    context = create_context(environment: "staging")

    expect(context.peek_treatment("exp_env")).to eq(0)

    context.set_attribute("environment", "production")
    expect(context.peek_treatment("exp_env")).to eq(1)
  end

  # Test 5: Ruby's data model has only `audience`; assignment-rule conditions
  # map to the same audience-filter path, so a condition on environment is
  # evaluated against the system attributes too.
  it "evaluates audience conditions on application against the system value" do
    context = create_context(application: "website")

    expect(context.peek_treatment("exp_app")).to eq(1)

    context.set_attribute("application", "other")
    expect(context.peek_treatment("exp_app")).to eq(0)
  end

  # Test 6: missing config means no key in the map; a filter on environment
  # doesn't match and nothing crashes.
  it "leaves the environment key out when no environment is configured" do
    context = create_context(environment: nil)

    expect { context.peek_treatment("exp_env") }.not_to raise_error
    expect(context.peek_treatment("exp_env")).to eq(0)
  end

  it "leaves the environment key out when the environment is empty" do
    context = create_context(environment: "")

    expect(context.peek_treatment("exp_env")).to eq(0)
  end

  it "leaves the application key out when no application is configured" do
    context = create_context(application: nil)

    expect(context.peek_treatment("exp_app")).to eq(0)
  end

  # Test 7: nothing extra published. The serialized payload carries only the
  # user-set attributes, never application/environment/app_version.
  it "does not publish application, environment or app_version attributes" do
    context = create_context(environment: "production", application: "website")
    context.treatment("exp_env")

    serializer = DefaultContextEventSerializer.new
    published = nil
    allow(event_handler).to receive(:publish) do |_ctx, event|
      published = serializer.serialize(event)
      publish_future
    end
    context.publish

    expect(published).not_to be_nil
    parsed = JSON.parse(published)
    expect(parsed).not_to have_key("attributes")
  end

  it "publishes only the user-set attributes, not the system ones" do
    context = create_context(environment: "production", application: "website")
    context.set_attribute("user_tier", "gold")
    context.treatment("exp_env")

    serializer = DefaultContextEventSerializer.new
    published = nil
    allow(event_handler).to receive(:publish) do |_ctx, event|
      published = serializer.serialize(event)
      publish_future
    end
    context.publish

    parsed = JSON.parse(published)
    names = parsed.fetch("attributes").map { |a| a["name"] }
    expect(names).to eq(["user_tier"])
    expect(names).not_to include("application", "environment", "app_version")
  end

  # Test 8: app_version is gone. A filter on app_version doesn't match even
  # though the client sends X-Application-Version: 0.
  it "does not inject app_version into the audience map" do
    context = create_context(application: "website", environment: "production")

    expect(context.peek_treatment("exp_app_version")).to eq(0)
  end

  it "still evaluates an app_version the user sets explicitly" do
    context = create_context(application: "website", environment: "production")
    context.set_attribute("app_version", "0")

    expect(context.peek_treatment("exp_app_version")).to eq(1)
  end
end

# The application/environment seeded into the evaluation map come from the
# configured client. Custom data provider and event handler must not drop them.
RSpec.describe "ABSmartly system attributes wiring" do
  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("system_attributes_context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }
  let(:data_result) { OpenStruct.new(data_future: data, success?: true) }

  def configured_client
    instance_double(Client,
                    application: "website",
                    environment: "production",
                    context_data: nil)
  end

  def build_sdk(provider:, handler:)
    config = ABSmartlyConfig.create
    config.client = configured_client
    config.context_data_provider = provider if provider
    config.context_event_handler = handler if handler
    ABSmartly.create(config)
  end

  it "uses the configured client's application/environment even with both custom providers" do
    provider = DefaultContextDataProvider.new(
      instance_double(Client, context_data: data_result)
    )
    handler = double("ContextEventHandler")
    allow(handler).to receive(:publish).and_return(OpenStruct.new(success?: true))

    sdk = build_sdk(provider: provider, handler: handler)

    context_config = ContextConfig.create
    context_config.set_unit(:session_id, "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
    context = sdk.create_context_with(context_config, data_result)

    # The strict environment=production audience matches only because the
    # configured client's environment seeds the evaluation map.
    expect(context.peek_treatment("exp_env")).to eq(1)
    expect(context.peek_treatment("exp_app")).to eq(1)
  end
end
