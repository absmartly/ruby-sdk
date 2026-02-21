# frozen_string_literal: true

require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "context_data_provider"
require "default_context_data_provider"
require "context_event_handler"
require "context_event_logger"
require "scheduled_executor_service"
require "audience_matcher"
require "json/unit"
require "logger"

RSpec.describe Context do
  let(:units) {
    {
      session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
      user_id: "123456789",
      email: "bleh@absmartly.com"
    }
  }
  let(:attributes) {
    {
      "attr1": "value1",
      "attr2": "value2",
      "attr3": 5
    }
  }
  let(:expected_variants) {
    {
      exp_test_ab: 1,
      exp_test_abc: 2,
      exp_test_not_eligible: 0,
      exp_test_fullon: 2,
      exp_test_new: 1
    }
  }
  let(:expected_variables) {
    {
      "banner.border": 1,
      "banner.size": "large",
      "button.color": "red",
      "submit.color": "blue",
      "submit.shape": "rect",
      "show-modal": true
    }
  }
  let(:variable_experiments) {
    {
      "banner.border": "exp_test_ab",
      "banner.size": "exp_test_ab",
      "button.color": "exp_test_abc",
      "card.width": "exp_test_not_eligible",
      "submit.color": "exp_test_fullon",
      "submit.shape": "exp_test_fullon",
      "show-modal": "exp_test_new"
    }
  }
  let(:publish_units) {
    [
      Unit.new("session_id", "pAE3a1i5Drs5mKRNq56adA"),
      Unit.new("user_id", "JfnnlDI7RTiF9RgfG2JNCw"),
      Unit.new("email", "IuqYkNRfEx5yClel4j3NbA")
    ]
  }
  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:clock_in_millis) { clock.to_i }

  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }

  let(:refresh_json) { resource("refreshed.json") }
  let(:refresh_data) { descr.deserialize(refresh_json, 0, refresh_json.length) }

  let(:audience_json) { resource("audience_context.json") }
  let(:audience_data) { descr.deserialize(audience_json, 0, audience_json.length) }

  let(:audience_strict_json) { resource("audience_strict_context.json") }
  let(:audience_strict_data) { descr.deserialize(audience_strict_json, 0, audience_strict_json.length) }

  let(:data_future) { OpenStruct.new(data_future: nil, success?: true) }

  let(:data_provider) { DefaultContextDataProvider.new(client_mock) }
  let(:data_future_ready) { data_provider.context_data }

  let(:failed_data_provider) { DefaultContextDataProvider.new(failed_client_mock) }
  let(:data_future_failed) { failed_data_provider.context_data }

  let(:refresh_data_provider) { DefaultContextDataProvider.new(client_mock(refresh_data)) }
  let(:refresh_data_future_ready) { refresh_data_provider.context_data }

  let(:audience_data_provider) { DefaultContextDataProvider.new(client_mock(audience_data)) }
  let(:audience_data_future_ready) { audience_data_provider.context_data }

  let(:audience_strict_data_provider) { DefaultContextDataProvider.new(client_mock(audience_strict_data)) }
  let(:audience_strict_data_future_ready) { audience_strict_data_provider.context_data }

  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:event_handler) do
    ev = instance_double(ContextEventHandler)
    allow(ev).to receive(:publish).and_return(publish_future)
    ev
  end
  let(:event_logger) do
    event_logger = MockContextEventLoggerProxy.new
    allow(event_logger).to receive(:handle_event).and_call_original
    event_logger
  end
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
  let(:failure) { Exception.new("FAILED") }
  let(:failure_future) { OpenStruct.new(exception: failure, success?: false, data_future: nil) }

  def http_client_mock
    http_client = instance_double(DefaultHttpClient)
    allow(http_client).to receive(:get).and_return(faraday_response(refresh_json))
    http_client
  end

  def client_mock(data_future = nil)
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data_future || data, success?: true))
    client
  end

  def failed_client_mock
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(failure_future)
    client
  end

  def create_context(data_future = nil, config: nil, evt_handler: nil, dt_provider: nil)
    if config.nil?
      config = ContextConfig.create
      config.set_units(units)
    end

    Context.create(clock, config, data_future || data_future_ready, dt_provider || data_provider,
                   evt_handler || event_handler, event_logger, variable_parser, audience_matcher)
  end

  def create_ready_context(evt_handler: nil)
    config = ContextConfig.create
    config.set_units(units)

    Context.create(clock, config, data_future_ready, data_provider,
                   evt_handler || event_handler, event_logger, variable_parser, audience_matcher)
  end

  def create_failed_context
    config = ContextConfig.create
    config.set_units(units)

    Context.create(clock, config, data_future_failed, failed_data_provider,
                   event_handler, event_logger, variable_parser, audience_matcher)
  end

  def faraday_response(content)
    env = Faraday::Env.from(status: 200, body: content,
                            response_headers: { "Content-Type" => "application/json" })
    Faraday::Response.new(env)
  end

  it "constructor sets overrides" do
    overrides = {
      "exp_test": 2,
      "exp_test_1": 1
    }

    config = ContextConfig.create
    config.set_units(units)
    config.set_overrides(overrides)

    context = create_context(config: config)
    overrides.each { |experiment_ame, variant| expect(context.override(experiment_ame)).to eq(variant) }
  end

  it "constructor sets custom assignments" do
    cassignments = {
      "exp_test": 2,
      "exp_test_1": 1
    }
    config = ContextConfig.create
    config.set_units(units)
    config.set_custom_assignments(cassignments)

    context = create_context(config: config)
    cassignments.each { |experiment_name, variant| expect(context.custom_assignment(experiment_name)).to eq(variant) }
  end

  it "becomes ready with completed future" do
    context = create_ready_context
    expect(context.ready?).to be_truthy
    expect(context.data).to eq(data)
  end

  it "becomes ready and failed with completed exceptionally future" do
    context = create_failed_context
    expect(context.ready?).to be_truthy
    expect(context.failed?).to be_truthy
  end

  it "calls event logger when ready" do
    create_ready_context

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::READY, data).once
  end

  it "callsEventLoggerWithException" do
    create_context(data_future_failed)

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED").once
  end

  it "throwsWhenNotReady" do
    context = create_context(data_future)
    expect(context.ready?).to be_falsey
    expect(context.failed?).to be_falsey

    not_ready_message = "ABSmartly Context is not yet ready"
    expect {
      context.peek_treatment("exp_test_ab")
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.treatment("exp_test_ab")
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.data
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.experiments
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.variable_value("banner.border", 17)
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.peek_variable_value("banner.border", 17)
    }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.variable_keys
    }.to raise_error(IllegalStateException, not_ready_message)
  end

  it "throws when closed" do
    context = create_ready_context
    expect(context.ready?).to be_truthy
    expect(context.failed?).to be_falsey

    publish_future = nil
    allow(event_handler).to receive(:publish).and_return(publish_future)
    context.close

    expect(context.closed?).to be_truthy

    closed_message = "ABSmartly Context is closed"
    expect {
      context.set_attribute("attr1", "value1")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_attributes("attr1": "value1")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_override("exp_test_ab", 2)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_overrides("exp_test_ab": 2)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_unit("test", "test")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_custom_assignment("exp_test_ab", 2)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_custom_assignments("exp_test_ab": 2)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.peek_treatment("exp_test_ab")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.treatment("exp_test_ab")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.track("goal1", nil)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.publish
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.data
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.experiments
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.variable_value("banner.border", 17)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.peek_variable_value("banner.border", 17)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.variable_keys
    }.to raise_error(IllegalStateException, closed_message)
  end

  it "experiments" do
    context = create_ready_context
    expect(context.ready?).to be_truthy

    experiments = data.experiments.map(&:name)
    expect(context.experiments).to eq(experiments)
  end

  it "set unit empty" do
    context = create_ready_context

    expect {
      context.set_unit("db_user_id", "")
    }.to raise_error(IllegalStateException, "Unit 'db_user_id' UID must not be blank.")
  end

  it "set unit throws on already set" do
    context = create_ready_context

    expect {
      context.set_unit("session_id", "new_uid")
    }.to raise_error(IllegalStateException,
                     "Unit 'session_id' already set.")
  end

  it "set override" do
    context = create_ready_context

    context.set_override("exp_test", 2)

    expect(context.override("exp_test")).to eq(2)

    context.set_override("exp_test", 3)
    expect(context.override("exp_test")).to eq(3)

    context.set_override("exp_test_2", 1)
    expect(context.override("exp_test_2")).to eq(1)

    overrides = {
      exp_test_new: 3,
      exp_test_new_2: 5
    }

    context.set_overrides(overrides)

    expect(context.override("exp_test")).to eq(3)
    expect(context.override("exp_test_2")).to eq(1)
    overrides.each { |experiment_name, variant| expect(context.override(experiment_name)).to eq(variant) }

    expect(context.override("exp_test_not_found")).to be_nil
  end

  it "set override clears assignment cache" do
    context = create_ready_context

    overrides = {
      exp_test_new: 3,
      exp_test_new_2: 5
    }

    context.set_overrides(overrides)

    overrides.each { |experiment_name, variant| expect(context.treatment(experiment_name)).to eq(variant) }
    expect(context.pending_count).to eq(overrides.size)

    # overriding again with the same variant shouldn't clear assignment cache
    overrides.each do |experiment_name, variant|
      context.set_override(experiment_name, variant)
      expect(context.treatment(experiment_name)).to eq(variant)
    end
    expect(context.pending_count).to eq(overrides.size)

    # overriding with the different variant should clear assignment cache
    overrides.each do |experiment_name, variant|
      context.set_override(experiment_name, (variant + 11))
      expect(context.treatment(experiment_name)).to eq(variant + 11)
    end

    expect(context.pending_count).to eq(overrides.size * 2)

    # overriding a computed assignment should clear assignment cache
    expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
    expect(context.pending_count).to eq(1 + overrides.size * 2)

    context.set_override("exp_test_ab", 9)
    expect(context.treatment("exp_test_ab")).to eq(9)
    expect(context.pending_count).to eq(2 + overrides.size * 2)
  end

  it "set override before ready" do
    context = create_context(data_future)
    expect(context.ready?).to be_falsey

    context = create_context(data_future)

    context.set_override("exp_test", 2)
    context.set_overrides(
      exp_test_new: 3,
      exp_test_new_2: 5
    )

    expect(context.override("exp_test")).to eq(2)
    expect(context.override("exp_test_new")).to eq(3)
    expect(context.override("exp_test_new_2")).to eq(5)
  end

  it "set_attribute and set_attributes" do
    context = create_ready_context

    context.set_attribute("attr1", "value1")
    context.set_attributes({ attr2: "value2", attr3: 15 })

    attrs = context.instance_variable_get(:@attributes)
    expect(attrs).to include(Attribute.new("attr1", "value1", clock_in_millis))
    expect(attrs).to include(Attribute.new(:attr2, "value2", clock_in_millis))
    expect(attrs).to include(Attribute.new(:attr3, 15, clock_in_millis))
  end

  it "set_attributes before ready" do
    context = create_context(data_future)
    expect(context.ready?).to be_falsey

    context.set_attribute("attr1", "value1")
    context.set_attributes({ attr2: "value2" })

    attrs = context.instance_variable_get(:@attributes)
    expect(attrs).to include(Attribute.new("attr1", "value1", clock_in_millis))
    expect(attrs).to include(Attribute.new(:attr2, "value2", clock_in_millis))
  end

  it "set custom assignment" do
    context = create_ready_context
    context.set_custom_assignment("exp_test", 2)

    expect(context.custom_assignment("exp_test")).to eq(2)

    context.set_custom_assignment("exp_test", 3)
    expect(context.custom_assignment("exp_test")).to eq(3)

    context.set_custom_assignment("exp_test_2", 1)
    expect(context.custom_assignment("exp_test_2")).to eq(1)

    cassignments = {
      exp_test_new: 3,
      exp_test_new_2: 5
    }

    context.set_custom_assignments(cassignments)

    expect(context.custom_assignment("exp_test")).to eq(3)
    expect(context.custom_assignment("exp_test_2")).to eq(1)

    cassignments.each { |experiment_name, variant| expect(context.custom_assignment(experiment_name)).to eq(variant) }

    expect(context.custom_assignment("exp_test_not_found")).to be_nil
  end

  it "set custom assignment does not override full on or not eligible assignments" do
    context = create_ready_context

    context.set_custom_assignment("exp_test_not_eligible", 3)
    context.set_custom_assignment("exp_test_fullon", 3)

    expect(context.treatment("exp_test_not_eligible")).to eq 0
    expect(context.treatment("exp_test_fullon")).to eq 2
  end

  it "set custom assignment clears assignment cache" do
    context = create_ready_context

    cassignments = {
      exp_test_ab: 2,
      exp_test_abc: 3
    }
    cassignments.each { |experiment_name, _| expect(expected_variants[experiment_name]).to eq(context.treatment(experiment_name)) }
    expect(context.pending_count).to eq(cassignments.size)

    context.set_custom_assignments(cassignments)

    cassignments.each { |experiment_name, variant| expect(context.treatment(experiment_name)).to eq(variant) }
    expect(context.pending_count).to eq(2 * cassignments.size)

    # overriding again with the same variant shouldn't clear assignment cache
    cassignments.each do |experiment_name, variant|
      context.set_custom_assignment(experiment_name, variant)
      expect(context.treatment(experiment_name)).to eq(variant)
    end
    cassignments.each do |experiment_name, variant|
      expect(context.treatment(experiment_name)).to eq(variant)
    end
    expect(context.pending_count).to eq(2 * cassignments.size)

    # overriding with the different variant should clear assignment cache
    cassignments.each do |experiment_name, variant|
      context.set_custom_assignment(experiment_name, (variant + 11))
      expect(context.treatment(experiment_name)).to eq(variant + 11)
    end

    expect(context.pending_count).to eq(cassignments.size * 3)
  end

  it "setCustomAssignmentsBeforeReady" do
    context = create_context(data_future)
    expect(context.ready?).to be_falsey

    context = create_ready_context
    context.set_custom_assignment("exp_test", 2)
    context.set_custom_assignments(
      exp_test_new: 3,
      exp_test_new_2: 5
    )

    expect(context.custom_assignment("exp_test")).to eq(2)
    expect(context.custom_assignment("exp_test_new")).to eq(3)
    expect(context.custom_assignment("exp_test_new_2")).to eq(5)
  end

  it "peek_treatment" do
    context = create_ready_context

    data.experiments.each do |experiment|
      expect(context.peek_treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym])
    end
    expect(context.peek_treatment("not_found")).to eq 0

    # call again
    data.experiments.each do |experiment|
      expect(context.peek_treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym])
    end
    expect(context.peek_treatment("not_found")).to eq(0)

    expect(context.pending_count).to eq(0)
  end

  it "peekVariableValue" do
    context = create_ready_context

    experiments = data.experiments.map(&:name)

    variable_experiments.each do |variable, experiment_name|
      actual = context.peek_variable_value(variable, 17)
      eligible = experiment_name != "exp_test_not_eligible"

      if eligible && experiments.include?(experiment_name)
        expect(expected_variables[variable]).to eq(actual)
      else
        expect(actual).to eq 17
      end
    end

    expect(context.pending_count).to eq(0)
  end

  it "peekVariableValueReturnsAssignedVariantOnAudienceMismatchNonStrictMode" do
    context = create_context(audience_data_future_ready)

    expect(context.peek_variable_value("banner.size", "small")).to eq "large"
  end

  it "peekVariableValueReturnsControlVariantOnAudienceMismatchStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.peek_variable_value("banner.size", "small")).to eq "small"
  end

  it "variable_value" do
    context = create_ready_context

    experiments = data.experiments.map(&:name)

    variable_experiments.each do |variable, experiment_name|
      actual = context.variable_value(variable, 17)
      eligible = experiment_name != "exp_test_not_eligible"

      if eligible && experiments.include?(experiment_name)
        expect(expected_variables[variable]).to eq actual
      else
        expect(actual).to eq 17
      end
    end

    expect(context.pending_count).to eq(experiments.size)
  end

  it "getVariableValueQueuesExposureWithAudienceMismatchFalseOnAudienceMatch" do
    context = create_context(audience_data_future_ready)
    context.set_attribute("age", 21)
    expect(context.variable_value("banner.size", "small")).to eq("large")
    expect(context.pending_count).to eq(1)

    allow(event_handler).to receive(:publish).and_return(publish_future)
    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units
    expected.attributes = [
      Attribute.new("age", 21, clock_in_millis)
    ]

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
    ]

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "getVariableValueQueuesExposureWithAudienceMismatchTrueOnAudienceMismatch" do
    context = create_context(audience_data_future_ready)

    expect(context.variable_value("banner.size", "small")).to eq("large")
    expect(context.pending_count).to eq(1)

    publish_future = nil
    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, true),
    ]

    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "getVariableValueQueuesExposureWithAudienceMismatchFalseAndControlVariantOnAudienceMismatchInStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.variable_value("banner.size", "small")).to eq("small")
    expect(context.pending_count).to eq(1)

    publish_future = nil
    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 0, clock_in_millis, false, true, false, false, false,
                   true)
    ]

    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "getVariableValueCallsEventLogger" do
    context = create_ready_context

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::READY, data).once
    context.variable_value("banner.border", nil)
    context.variable_value("banner.size", nil)

    exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
    ]

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposures.first).exactly(exposures.length).time

    event_logger.clear
    context.variable_value("banner.border", nil)
    context.variable_value("banner.size", nil)

    expect(event_logger.called).to eq(0)
  end

  it "getVariableKeys" do
    context = create_context(refresh_data_future_ready)

    expect(variable_experiments).to eq(context.variable_keys)
  end

  it "getCustomFieldKeys" do
    context = create_context(data_future_ready)

    expect(["country", "languages", "overrides"]).to eq(context.custom_field_keys)
  end

  it "getCustomFieldValues" do
    context = create_context(data_future_ready)

    expect(context.custom_field_value("not_found", "not_found")).to be_nil
    expect(context.custom_field_value("exp_test_ab", key: "not_found")).to be_nil
    expect(context.custom_field_value("exp_test_ab", "country")).to eq("US,PT,ES,DE,FR")
    expect(context.custom_field_type("exp_test_ab", "country")).to eq("string")

    data = {"123":  1, "456": 0}
    expect(context.custom_field_value("exp_test_ab", "overrides")).to eq(data)
    expect(context.custom_field_type("exp_test_ab", "overrides")).to eq("json")

    expect(context.custom_field_value("exp_test_ab", "languages")).to be_nil
    expect(context.custom_field_type("exp_test_ab", "languages")).to be_nil

    expect(context.custom_field_value("exp_test_abc", "overrides")).to be_nil
    expect(context.custom_field_type("exp_test_abc", "overrides")).to be_nil

    expect(context.custom_field_value("exp_test_abc", "languages")).to eq("en-US,en-GB,pt-PT,pt-BR,es-ES,es-MX")
    expect(context.custom_field_type("exp_test_abc", "languages")).to eq("string")

    expect(context.custom_field_value("exp_test_no_custom_fields", "country")).to be_nil
    expect(context.custom_field_type("exp_test_no_custom_fields", "country")).to be_nil

    expect(context.custom_field_type("exp_test_no_custom_fields", "overrides")).to be_nil
    expect(context.custom_field_value("exp_test_no_custom_fields", "overrides")).to be_nil

    expect(context.custom_field_type("exp_test_no_custom_fields", "languages")).to be_nil
    expect(context.custom_field_value("exp_test_no_custom_fields", "languages")).to be_nil

  end

  it "peek_treatmentReturnsOverrideVariant" do
    context = create_ready_context

    data.experiments.each do |experiment|
      context.set_override(experiment.name, (11 + expected_variants[experiment.name.to_sym]))
    end
    context.set_override("not_found", 3)

    data.experiments.each do |experiment|
      expect(context.peek_treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym] + 11)
    end
    expect(context.peek_treatment("not_found")).to eq(3)

    # call again
    data.experiments.each do |experiment|
      expect(context.peek_treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym] + 11)
    end
    expect(context.peek_treatment("not_found")).to eq 3

    expect(context.pending_count).to eq 0
  end

  it "peek_treatmentReturnsAssignedVariantOnAudienceMismatchNonStrictMode" do
    context = create_context(audience_data_future_ready)

    expect(context.peek_treatment("exp_test_ab")).to eq 1
  end

  it "peek_treatmentReturnsControlVariantOnAudienceMismatchStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.peek_treatment("exp_test_ab")).to eq 0
  end

  it "peek_treatmentReEvaluatesAudienceWhenAttributesChangeInStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.peek_treatment("exp_test_ab")).to eq 0

    context.set_attribute("age", 25)

    expect(context.peek_treatment("exp_test_ab")).to eq 1
    expect(context.pending_count).to eq 0
  end

  it "peek_treatmentReEvaluatesAudienceWhenAttributesChangeInNonStrictMode" do
    context = create_context(audience_data_future_ready)

    expect(context.peek_treatment("exp_test_ab")).to eq 1

    context.set_attribute("age", 25)

    expect(context.peek_treatment("exp_test_ab")).to eq 1
    expect(context.pending_count).to eq 0
  end

  it "peek_treatmentDoesNotReEvaluateAudienceWhenNoNewAttributesSet" do
    context = create_context(audience_strict_data_future_ready)

    context.set_attribute("age", 15)

    expect(context.peek_treatment("exp_test_ab")).to eq 0
    expect(context.peek_treatment("exp_test_ab")).to eq 0
    expect(context.pending_count).to eq 0
  end

  it "treatment" do
    context = create_ready_context(evt_handler: event_handler)

    data.experiments.each do |experiment|
      expect(context.treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym])
    end
    expect(context.treatment("not_found")).to eq 0
    expect(context.pending_count).to eq(1 + data.experiments.size)

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis,
                   true, true, false, false, false, false),
      Exposure.new(2, "exp_test_abc", "session_id", 2, clock_in_millis,
                   true, true, false, false, false, false),
      Exposure.new(3, "exp_test_not_eligible", "user_id", 0, clock_in_millis,
                   true, false, false, false, false, false),
      Exposure.new(4, "exp_test_fullon", "session_id", 2, clock_in_millis,
                   true, true, false, true, false, false),
      Exposure.new(0, "not_found", nil, 0, clock_in_millis,
                   false, true, false, false, false, false),
    ]
    publish_future = nil
    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish
    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
    context.close
  end

  it "treatmentReturnsOverrideVariant" do
    context = create_ready_context(evt_handler: event_handler)

    data.experiments.each do |experiment|
      context.set_override(experiment.name, 11 + expected_variants[experiment.name.to_s.to_sym])
      context.set_override("not_found", 3)
    end

    data.experiments.each do |experiment|
      expect(context.treatment(experiment.name)).to eq(expected_variants[experiment.name.to_s.to_sym] + 11)
    end
    expect(context.treatment("not_found")).to eq(3)
    expect(context.pending_count).to eq(1 + data.experiments.length)

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 12, clock_in_millis, false, true, true, false, false,
                   false),
      Exposure.new(2, "exp_test_abc", "session_id", 13, clock_in_millis, false, true, true, false, false,
                   false),
      Exposure.new(3, "exp_test_not_eligible", "user_id", 11, clock_in_millis, false, true, true, false, false,
                   false),
      Exposure.new(4, "exp_test_fullon", "session_id", 13, clock_in_millis, false, true, true, false, false,
                   false),
      Exposure.new(0, "not_found", nil, 3, clock_in_millis, false, true, true, false, false, false),
    ]

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
    context.close
  end

  it "treatmentQueuesExposureOnce" do
    context = create_ready_context

    data.experiments.each { |experiment| context.treatment(experiment.name) }
    context.treatment("not_found")

    expect(context.pending_count).to eq(1 + data.experiments.length)

    # call again
    data.experiments.each { |experiment| context.treatment(experiment.name) }
    context.treatment("not_found")

    expect(context.pending_count).to eq(1 + data.experiments.length)

    context.publish

    expect(event_handler).to have_received(:publish).once

    expect(context.pending_count).to eq(0)

    data.experiments.each { |experiment| context.treatment(experiment.name) }
    context.treatment("not_found")
    expect(context.pending_count).to eq(0)

    context.close
  end

  it "treatmentQueuesExposureWithAudienceMismatchFalseOnAudienceMatch" do
    context = create_context(audience_data_future_ready, evt_handler: event_handler)
    context.set_attribute("age", 21)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(1)

    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units
    expected.attributes = [
      Attribute.new("age", 21, clock_in_millis),
    ]

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
    ]

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "treatmentQueuesExposureWithAudienceMismatchTrueOnAudienceMismatch" do
    context = create_context(audience_data_future_ready)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(1)

    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, true),
    ]

    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "treatmentQueuesExposureWithAudienceMismatchTrueAndControlVariantOnAudienceMismatchInStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.treatment("exp_test_ab")).to eq(0)
    expect(context.pending_count).to eq(1)

    allow(event_handler).to receive(:publish).and_return(publish_future)

    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 0, clock_in_millis, false, true, false, false, false,
                   true),
    ]

    context.publish
    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "treatmentReEvaluatesAudienceWhenAttributesChangeInStrictMode" do
    context = create_context(audience_strict_data_future_ready)

    expect(context.treatment("exp_test_ab")).to eq(0)
    expect(context.pending_count).to eq(1)

    context.set_attribute("age", 25)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(2)
  end

  it "treatmentReEvaluatesAudienceWhenAttributesChangeInNonStrictMode" do
    context = create_context(audience_data_future_ready)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(1)

    context.set_attribute("age", 25)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(2)
  end

  it "treatmentDoesNotReEvaluateAudienceWhenNoNewAttributesSet" do
    context = create_context(audience_strict_data_future_ready)

    context.set_attribute("age", 15)

    expect(context.treatment("exp_test_ab")).to eq(0)
    expect(context.pending_count).to eq(1)

    expect(context.treatment("exp_test_ab")).to eq(0)
    expect(context.pending_count).to eq(1)
  end

  it "treatmentDoesNotReEvaluateAudienceForExperimentsWithoutAudienceFilter" do
    context = create_ready_context

    expect(context.treatment("exp_test_abc")).to eq(2)
    expect(context.pending_count).to eq(1)

    context.set_attribute("age", 25)

    expect(context.treatment("exp_test_abc")).to eq(2)
    expect(context.pending_count).to eq(1)
  end

  it "treatmentReEvaluatesFromAudienceMismatchToMatchInStrictMode" do
    context = create_context(audience_strict_data_future_ready, evt_handler: event_handler)

    expect(context.treatment("exp_test_ab")).to eq(0)
    expect(context.pending_count).to eq(1)

    allow(event_handler).to receive(:publish).and_return(publish_future)
    context.publish

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 0, clock_in_millis, false, true, false, false, false, true)
    ]

    expect(event_handler).to have_received(:publish).with(context, expected).once

    context.set_attribute("age", 30)

    expect(context.treatment("exp_test_ab")).to eq(1)
    expect(context.pending_count).to eq(1)

    context.publish

    expected2 = PublishEvent.new
    expected2.hashed = true
    expected2.published_at = clock_in_millis
    expected2.units = publish_units
    expected2.attributes = [
      Attribute.new("age", 30, clock_in_millis)
    ]

    expected2.exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false)
    ]

    expect(event_handler).to have_received(:publish).with(context, expected2).once
  end

  it "treatmentCallsEventLogger" do
    event_logger.clear
    context = create_ready_context
    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::READY, data).once

    context.treatment("exp_test_ab")
    context.treatment("not_found")

    exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
      Exposure.new(0, "not_found", nil, 0, clock_in_millis, false, true, false, false, false, false),
    ]

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposures[0]).once
    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::EXPOSURE, exposures[1]).once

    event_logger.clear
    context.treatment("exp_test_ab")
    context.treatment("not_found")

    expect(event_logger.called).to eq(0)
  end

  it "track" do
    context = create_ready_context
    context.track("goal1", { amount: 125, hours: 245 })
    context.track("goal2", { tries: 7 })

    expect(context.pending_count).to eq(2)

    context.track("goal2", { tests: 12 })
    context.track("goal3", nil)

    expect(context.pending_count).to eq(4)

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.goals = [
      GoalAchievement.new("goal1", clock_in_millis,
                          { amount: 125, hours: 245 }),
      GoalAchievement.new("goal2", clock_in_millis, { tries: 7 }),
      GoalAchievement.new("goal2", clock_in_millis, { tests: 12 }),
      GoalAchievement.new("goal3", clock_in_millis, nil),
    ]

    context.publish

    expect(event_handler).to have_received(:publish).once
    expect(event_handler).to have_received(:publish).with(context, expected).once

    context.close
  end

  it "trackQueuesWhenNotReady" do
    context = create_context(data_future)

    context.track("goal1", { amount: 125, hours: 245 })
    context.track("goal2", { tries: 7 })
    context.track("goal3", nil)

    expect(context.pending_count).to eq(3)
  end

  it "publish does not call event handler when queue is empty" do
    context = create_ready_context
    expect(context.pending_count).to eq(0)
    context.publish

    expect(event_handler).to have_received(:publish).exactly(0).time
  end

  it "publishCallsEventLogger" do
    event_logger.clear
    context = create_ready_context
    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::READY, data).once

    context.track("goal1", { amount: 125, hours: 245 })

    expected = PublishEvent.new
    expected.hashed = true
    expected.published_at = clock_in_millis
    expected.units = publish_units

    expected.goals = [
      GoalAchievement.new("goal1", clock_in_millis,
                          { amount: 125, hours: 245 }),
    ]
    allow(event_handler).to receive(:publish).and_return(failure_future)

    context.publish

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::PUBLISH, expected).once
    expect(event_handler).to have_received(:publish).with(context, expected).once
  end

  it "publishCallsEventLoggerOnError" do
    context = create_context(data_future_failed)

    context.track("goal1", { amount: 125, hours: 245 })

    allow(event_handler).to receive(:publish).and_return(failure_future)
    actual = context.publish
    expect(actual).to eq(failure)

    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED").at_least(:once)
  end

  it "publish Does Not Call event handler When Failed" do
    context = create_context(data_future_failed)
    expect(context.ready?).to be_truthy
    expect(context.failed?).to be_truthy

    context.treatment("exp_test_abc")
    context.track("goal1", { amount: 125, hours: 245 })

    expect(context.pending_count).to eq(2)

    context.publish

    expect(event_handler).to have_received(:publish).exactly(0).time
  end

  it "publishExceptionally" do
    ev = instance_double(ContextEventHandler)
    context = create_ready_context(evt_handler: ev)
    expect(context.ready?).to be_truthy
    expect(context.failed?).to be_falsey

    context.track("goal1", { amount: 125, hours: 245 })

    expect(context.pending_count).to eq(1)

    allow(ev).to receive(:publish).and_return(failure_future)
    actual = context.publish

    expect(actual.exception).to eq(failure)
    expect(ev).to have_received(:publish).once
  end

  it "close" do
    context = create_ready_context
    expect(context.ready?).to be_truthy

    context.track(" goal1 ", { amount: 125, hours: 245 })

    expect(context.closed?).to be_falsey

    context.close

    expect(context.closed?).to be_truthy

    expect(event_handler).to have_received(:publish).once
  end

  it " refresh " do
    context = create_context(refresh_data_future_ready, dt_provider: refresh_data_provider)
    expect(context.ready?).to be_truthy

    context.refresh

    experiments = refresh_data.experiments.map { |x| x.name }
    expect(context.experiments).to eq(experiments)
  end

  describe "publish behavior" do
    it "publishes pending events on manual publish" do
      context = create_ready_context
      context.track("goal1", { amount: 100 })
      context.treatment("exp_test_ab")

      expect(context.pending_count).to eq(2)

      context.publish

      expect(context.pending_count).to eq(0)
      expect(event_handler).to have_received(:publish).once
    end

    it "does not publish when no pending events exist" do
      context = create_ready_context
      expect(context.pending_count).to eq(0)

      context.publish

      expect(event_handler).not_to have_received(:publish)
    end

    it "clears pending count after successful publish" do
      context = create_ready_context
      context.track("goal1", nil)
      context.track("goal2", nil)
      context.track("goal3", nil)

      expect(context.pending_count).to eq(3)

      context.publish

      expect(context.pending_count).to eq(0)
    end

    it "publishes on close when pending events exist" do
      context = create_ready_context
      context.track("goal1", { amount: 50 })

      expect(context.pending_count).to eq(1)

      context.close

      expect(event_handler).to have_received(:publish).once
      expect(context.closed?).to be_truthy
    end

    it "does not publish on close when no pending events" do
      context = create_ready_context
      expect(context.pending_count).to eq(0)

      context.close

      expect(event_handler).not_to have_received(:publish)
      expect(context.closed?).to be_truthy
    end
  end

  describe "refresh error handling" do
    it "handles provider error during refresh" do
      context = create_context(data_future_ready, dt_provider: data_provider)
      expect(context.ready?).to be_truthy
      expect(context.failed?).to be_falsey

      allow(data_provider).to receive(:context_data).and_return(failure_future)

      context.refresh

      expect(context.failed?).to be_truthy
      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED")
    end

    it "preserves pending events during failed refresh" do
      context = create_context(data_future_ready, dt_provider: data_provider)
      context.track("goal1", { amount: 100 })
      context.treatment("exp_test_ab")

      expect(context.pending_count).to eq(2)

      allow(data_provider).to receive(:context_data).and_return(failure_future)
      context.refresh

      expect(context.pending_count).to eq(2)
      expect(context.failed?).to be_truthy
    end

    it "does not refresh when context already failed" do
      context = create_failed_context
      expect(context.failed?).to be_truthy

      initial_data = context.data
      context.refresh

      expect(context.data).to eq(initial_data)
    end

    it "updates data on successful refresh" do
      context = create_context(data_future_ready, dt_provider: refresh_data_provider)
      original_experiments = context.experiments.dup

      context.refresh

      new_experiments = context.experiments
      expect(new_experiments).not_to be_empty
    end

    it "logs refresh event on success" do
      event_logger.clear
      context = create_context(data_future_ready, dt_provider: refresh_data_provider)
      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::READY, anything).once

      context.refresh

      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::REFRESH, anything).once
    end

    it "throws when refreshing closed context" do
      context = create_ready_context
      context.close

      expect {
        context.refresh
      }.to raise_error(IllegalStateException, "ABSmartly Context is closed")
    end
  end

  describe "error recovery and resilience" do
    it "context remains usable after failed publish" do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(failure_future)

      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)

      result = context.publish
      expect(result.exception).to eq(failure)

      expect(context.ready?).to be_truthy
      expect(context.closed?).to be_falsey
      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
    end

    it "queues new events after failed publish" do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(failure_future)

      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)
      context.publish

      context.track("goal2", nil)
      expect(context.pending_count).to eq(2)
    end

    it "calls error callback on publish failure" do
      context = create_context(data_future_failed)
      context.track("goal1", nil)

      allow(event_handler).to receive(:publish).and_return(failure_future)
      context.publish

      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED")
    end

    it "failed context clears pending events on publish" do
      context = create_failed_context
      context.track("goal1", nil)
      context.track("goal2", nil)

      expect(context.pending_count).to eq(2)

      context.publish

      expect(context.pending_count).to eq(0)
    end

    it "failed context returns control variant" do
      context = create_failed_context
      expect(context.failed?).to be_truthy

      expect(context.treatment("any_experiment")).to eq(0)
      expect(context.peek_treatment("any_experiment")).to eq(0)
    end
  end

  describe "attribute timestamp validation" do
    it "stores correct timestamp on attributes" do
      context = create_ready_context

      context.set_attribute("attr1", "value1")
      context.set_attribute("attr2", "value2")

      attrs = context.instance_variable_get(:@attributes)
      expect(attrs.length).to eq(2)
      expect(attrs[0].set_at).to eq(clock_in_millis)
      expect(attrs[1].set_at).to eq(clock_in_millis)
    end

    it "includes attributes with timestamps in publish event" do
      context = create_ready_context(evt_handler: event_handler)

      context.set_attribute("test_attr", "test_value")
      context.track("goal1", nil)

      expected = PublishEvent.new
      expected.hashed = true
      expected.published_at = clock_in_millis
      expected.units = publish_units
      expected.attributes = [
        Attribute.new("test_attr", "test_value", clock_in_millis)
      ]
      expected.goals = [
        GoalAchievement.new("goal1", clock_in_millis, nil)
      ]

      context.publish

      expect(event_handler).to have_received(:publish).with(context, expected).once
    end

    it "preserves all attributes across multiple set operations" do
      context = create_ready_context

      context.set_attribute("attr1", "value1")
      context.set_attribute("attr2", "value2")
      context.set_attributes({ attr3: "value3", attr4: "value4" })

      attrs = context.instance_variable_get(:@attributes)
      expect(attrs.length).to eq(4)

      names = attrs.map(&:name)
      expect(names).to include("attr1")
      expect(names).to include("attr2")
      expect(names).to include(:attr3)
      expect(names).to include(:attr4)
    end
  end

  describe "variable override precedence" do
    it "override takes precedence over computed assignment" do
      context = create_ready_context

      computed = context.treatment("exp_test_ab")
      expect(computed).to eq(expected_variants[:exp_test_ab])

      context.set_override("exp_test_ab", 99)

      overridden = context.treatment("exp_test_ab")
      expect(overridden).to eq(99)
    end

    it "override takes precedence over custom assignment" do
      context = create_ready_context

      context.set_custom_assignment("exp_test_ab", 5)
      custom = context.treatment("exp_test_ab")
      expect(custom).to eq(5)

      context.set_override("exp_test_ab", 10)
      overridden = context.treatment("exp_test_ab")
      expect(overridden).to eq(10)
    end

    it "custom assignment takes precedence over computed for eligible experiments" do
      context = create_ready_context

      computed = context.peek_treatment("exp_test_ab")
      expect(computed).to eq(expected_variants[:exp_test_ab])

      context.set_custom_assignment("exp_test_ab", 99)

      custom = context.treatment("exp_test_ab")
      expect(custom).to eq(99)
    end

    it "complex precedence scenario with override custom and computed" do
      context = create_ready_context

      computed = context.peek_treatment("exp_test_ab")
      expect(computed).to eq(expected_variants[:exp_test_ab])

      context.set_custom_assignment("exp_test_ab", 5)
      expect(context.treatment("exp_test_ab")).to eq(5)

      context.set_override("exp_test_ab", 10)
      expect(context.treatment("exp_test_ab")).to eq(10)

      context.set_override("exp_test_ab", 15)
      expect(context.treatment("exp_test_ab")).to eq(15)
    end

    it "peek_treatment respects override precedence" do
      context = create_ready_context

      context.set_override("exp_test_ab", 42)

      expect(context.peek_treatment("exp_test_ab")).to eq(42)
      expect(context.pending_count).to eq(0)
    end
  end

  describe "cache invalidation on refresh" do
    def modified_data(experiment_name, &block)
      json_copy = JSON.parse(resource("context.json"))
      json_copy["experiments"].each do |exp|
        block.call(exp) if exp["name"] == experiment_name
      end
      descr.deserialize(JSON.generate(json_copy), 0, JSON.generate(json_copy).length)
    end

    def create_refreshable_context(modified)
      modified_client = instance_double(Client)
      allow(modified_client).to receive(:context_data).and_return(
        OpenStruct.new(data_future: modified, success?: true)
      )
      modified_provider = DefaultContextDataProvider.new(modified_client)
      create_context(data_future_ready, dt_provider: modified_provider)
    end

    it "should pick up changes in experiment stopped" do
      modified = modified_data("exp_test_ab") { |exp| exp["fullOnVariant"] = 2 }
      context = create_refreshable_context(modified)

      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(2)
      expect(context.pending_count).to eq(2)
    end

    it "should pick up changes in experiment started" do
      started_json = JSON.parse(resource("context.json"))
      started_json["experiments"].each do |exp|
        exp["fullOnVariant"] = 2 if exp["name"] == "exp_test_ab"
      end
      started_data = descr.deserialize(JSON.generate(started_json), 0, JSON.generate(started_json).length)

      restarted_json = JSON.parse(resource("context.json"))
      restarted_json["experiments"].each do |exp|
        exp["fullOnVariant"] = 0 if exp["name"] == "exp_test_ab"
      end
      restarted_data = descr.deserialize(JSON.generate(restarted_json), 0, JSON.generate(restarted_json).length)

      restarted_client = instance_double(Client)
      allow(restarted_client).to receive(:context_data).and_return(
        OpenStruct.new(data_future: restarted_data, success?: true)
      )
      restarted_provider = DefaultContextDataProvider.new(restarted_client)

      started_client = instance_double(Client)
      allow(started_client).to receive(:context_data).and_return(
        OpenStruct.new(data_future: started_data, success?: true)
      )
      started_provider = DefaultContextDataProvider.new(started_client)

      context = create_context(started_provider.context_data, dt_provider: restarted_provider)

      expect(context.treatment("exp_test_ab")).to eq(2)
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
      expect(context.pending_count).to eq(2)
    end

    it "should pick up changes in experiment fullon" do
      modified = modified_data("exp_test_abc") { |exp| exp["fullOnVariant"] = 1 }
      context = create_refreshable_context(modified)

      expect(context.treatment("exp_test_abc")).to eq(expected_variants[:exp_test_abc])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(2)
    end

    it "should pick up changes in experiment traffic split" do
      modified = modified_data("exp_test_not_eligible") do |exp|
        exp["trafficSplit"] = [0.0, 1.0]
      end
      context = create_refreshable_context(modified)

      expect(context.treatment("exp_test_not_eligible")).to eq(expected_variants[:exp_test_not_eligible])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_not_eligible")).to eq(2)
      expect(context.pending_count).to eq(2)
    end

    it "should pick up changes in experiment iteration" do
      modified = modified_data("exp_test_abc") do |exp|
        exp["iteration"] = 2
        exp["trafficSeedHi"] = 398724581
        exp["seedHi"] = 34737352
      end
      context = create_refreshable_context(modified)

      expect(context.treatment("exp_test_abc")).to eq(expected_variants[:exp_test_abc])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(2)
    end

    it "should pick up changes in experiment id" do
      modified = modified_data("exp_test_abc") do |exp|
        exp["id"] = 11
        exp["trafficSeedHi"] = 398724581
        exp["seedHi"] = 34737352
      end
      context = create_refreshable_context(modified)

      expect(context.treatment("exp_test_abc")).to eq(expected_variants[:exp_test_abc])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_abc")).to eq(1)
      expect(context.pending_count).to eq(2)
    end

    it "should not re-queue exposures after refresh when not changed" do
      context = create_context(data_future_ready, dt_provider: data_provider)

      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
      expect(context.pending_count).to eq(1)
    end

    it "should not re-queue when not changed with override" do
      context = create_context(data_future_ready, dt_provider: data_provider)

      context.set_override("exp_test_ab", 3)
      expect(context.treatment("exp_test_ab")).to eq(3)
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(3)
      expect(context.pending_count).to eq(1)
    end

    it "should keep overrides after refresh" do
      modified = modified_data("exp_test_ab") { |exp| exp["fullOnVariant"] = 2 }
      context = create_refreshable_context(modified)

      context.set_override("exp_test_ab", 99)
      expect(context.treatment("exp_test_ab")).to eq(99)
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(99)
      expect(context.pending_count).to eq(1)
    end

    it "should keep custom assignments after refresh" do
      modified = modified_data("exp_test_ab") { |exp| exp["fullOnVariant"] = 2 }
      context = create_refreshable_context(modified)

      context.set_custom_assignment("exp_test_ab", 2)
      expect(context.treatment("exp_test_ab")).to eq(2)
      expect(context.pending_count).to eq(1)

      context.refresh

      expect(context.treatment("exp_test_ab")).to eq(2)
      expect(context.pending_count).to eq(2)
    end

    it "should not re-queue when not changed on audience mismatch" do
      aud_context = create_context(audience_data_future_ready, dt_provider: audience_data_provider)

      expect(aud_context.treatment("exp_test_ab")).to eq(1)
      expect(aud_context.pending_count).to eq(1)

      aud_context.refresh

      expect(aud_context.treatment("exp_test_ab")).to eq(1)
      expect(aud_context.pending_count).to eq(1)
    end
  end

  describe "treatment queues exposure after peek" do
    it "should queue exposure after peek" do
      context = create_ready_context

      data.experiments.each do |experiment|
        expect(context.peek_treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym])
      end
      expect(context.pending_count).to eq(0)

      data.experiments.each do |experiment|
        expect(context.treatment(experiment.name)).to eq(expected_variants[experiment.name.to_sym])
      end
      expect(context.pending_count).to eq(data.experiments.size)
    end
  end

  describe "treatment with custom assignment variant" do
    it "should queue exposure with custom assignment variant" do
      context = create_ready_context(evt_handler: event_handler)

      context.set_custom_assignment("exp_test_ab", 2)
      expect(context.treatment("exp_test_ab")).to eq(2)
      expect(context.pending_count).to eq(1)

      context.publish

      expected = PublishEvent.new
      expected.hashed = true
      expected.published_at = clock_in_millis
      expected.units = publish_units

      expected.exposures = [
        Exposure.new(1, "exp_test_ab", "session_id", 2, clock_in_millis,
                     true, true, false, false, true, false),
      ]

      expect(event_handler).to have_received(:publish).once
      expect(event_handler).to have_received(:publish).with(context, expected).once
    end
  end

  describe "track validation" do
    it "should not throw when goal property values are numbers" do
      context = create_ready_context

      expect {
        context.track("goal1", { amount: 125, hours: 245 })
      }.not_to raise_error
      expect(context.pending_count).to eq(1)
    end

    it "should be callable before ready" do
      context = create_context(data_future)
      expect(context.ready?).to be_falsey

      expect {
        context.track("goal1", { amount: 125 })
      }.not_to raise_error
      expect(context.pending_count).to eq(1)
    end

    it "should track goals with nil properties" do
      context = create_ready_context

      expect {
        context.track("goal1", nil)
      }.not_to raise_error
      expect(context.pending_count).to eq(1)
    end
  end

  describe "publish includes data" do
    it "should include exposure data" do
      context = create_ready_context(evt_handler: event_handler)

      context.treatment("exp_test_ab")

      expected = PublishEvent.new
      expected.hashed = true
      expected.published_at = clock_in_millis
      expected.units = publish_units
      expected.exposures = [
        Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis,
                     true, true, false, false, false, false),
      ]

      context.publish

      expect(event_handler).to have_received(:publish).once
      expect(event_handler).to have_received(:publish).with(context, expected).once
    end

    it "should include goal data" do
      context = create_ready_context(evt_handler: event_handler)

      context.track("goal1", { amount: 125, hours: 245 })

      expected = PublishEvent.new
      expected.hashed = true
      expected.published_at = clock_in_millis
      expected.units = publish_units
      expected.goals = [
        GoalAchievement.new("goal1", clock_in_millis, { amount: 125, hours: 245 })
      ]

      context.publish

      expect(event_handler).to have_received(:publish).once
      expect(event_handler).to have_received(:publish).with(context, expected).once
    end

    it "should include attribute data" do
      context = create_ready_context(evt_handler: event_handler)

      context.set_attribute("attr1", "value1")
      context.track("goal1", nil)

      expected = PublishEvent.new
      expected.hashed = true
      expected.published_at = clock_in_millis
      expected.units = publish_units
      expected.attributes = [
        Attribute.new("attr1", "value1", clock_in_millis)
      ]
      expected.goals = [
        GoalAchievement.new("goal1", clock_in_millis, nil)
      ]

      context.publish

      expect(event_handler).to have_received(:publish).once
      expect(event_handler).to have_received(:publish).with(context, expected).once
    end

    it "should not clear queue on failure" do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(failure_future)

      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)
      expect(context.pending_count).to eq(1)

      context.publish

      context.track("goal2", nil)
      expect(context.pending_count).to eq(2)
    end
  end

  describe "finalize operations" do
    it "should not call client publish when queue is empty" do
      context = create_ready_context
      expect(context.pending_count).to eq(0)

      context.close

      expect(event_handler).not_to have_received(:publish)
      expect(context.closed?).to be_truthy
    end

    it "should call client publish" do
      context = create_ready_context(evt_handler: event_handler)

      context.treatment("exp_test_ab")
      context.track("goal1", nil)

      context.close

      expect(event_handler).to have_received(:publish).once
      expect(context.closed?).to be_truthy
    end

    it "should stop accepting events after close" do
      context = create_ready_context
      context.close

      expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException)
      expect { context.track("goal1", nil) }.to raise_error(IllegalStateException)
      expect { context.publish }.to raise_error(IllegalStateException)
    end
  end

  describe "unit management" do
    it "should set a unit" do
      context = create_ready_context

      context.set_unit("db_user_id", "new_uid")

      units_ivar = context.instance_variable_get(:@units)
      expect(units_ivar["db_user_id"]).to eq("new_uid")
    end

    it "should be callable before ready" do
      context = create_context(data_future)
      expect(context.ready?).to be_falsey

      expect { context.set_unit("db_user_id", "some_uid") }.not_to raise_error
    end
  end

  describe "refresh event logging" do
    it "should call event logger when refresh failed" do
      context = create_context(data_future_ready, dt_provider: data_provider)
      expect(context.ready?).to be_truthy

      allow(data_provider).to receive(:context_data).and_return(failure_future)

      event_logger.clear
      context.refresh

      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED").once
    end

    it "should call event logger on refresh success" do
      context = create_context(data_future_ready, dt_provider: refresh_data_provider)
      expect(context.ready?).to be_truthy

      event_logger.clear
      context.refresh

      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::REFRESH, anything).once
    end
  end

  describe "variableValue queues exposures" do
    it "should queue exposures after peekVariable" do
      context = create_ready_context

      expect(context.peek_variable_value("banner.border", 17)).to eq(1)
      expect(context.pending_count).to eq(0)

      expect(context.variable_value("banner.border", 17)).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "should queue exposures only once" do
      context = create_ready_context

      context.variable_value("banner.border", 17)
      context.variable_value("banner.size", 17)
      expect(context.pending_count).to eq(1)

      context.variable_value("banner.border", 17)
      context.variable_value("banner.size", 17)
      expect(context.pending_count).to eq(1)
    end

    it "should return default value on unknown variable" do
      context = create_ready_context

      expect(context.variable_value("unknown_variable", 42)).to eq(42)
    end
  end

  describe "peekVariableValue edge cases" do
    it "should return default value on unknown override variant" do
      context = create_ready_context
      context.set_override("exp_test_ab", 99)

      expect(context.peek_variable_value("banner.border", 42)).to eq(42)
    end
  end

  describe "track event logger" do
    it "should call event logger" do
      event_logger.clear
      context = create_ready_context
      event_logger.clear

      context.track("goal1", { amount: 125, hours: 245 })

      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::GOAL,
        satisfy { |goal| goal.name == "goal1" && goal.properties == { amount: 125, hours: 245 } }
      ).once
    end
  end

  describe "publish event logger on success" do
    it "should call event logger on publish success" do
      event_logger.clear
      context = create_ready_context(evt_handler: event_handler)
      event_logger.clear

      context.track("goal1", nil)
      context.publish

      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::PUBLISH, instance_of(PublishEvent)
      ).once
    end
  end

  describe "finalize event logging" do
    it "should call event logger on close success" do
      event_logger.clear
      context = create_ready_context(evt_handler: event_handler)
      event_logger.clear

      context.track("goal1", nil)
      context.close

      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::PUBLISH, instance_of(PublishEvent)
      ).once
      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::CLOSE, nil
      ).once
    end

    it "should call event logger on close error" do
      ev = instance_double(ContextEventHandler)
      allow(ev).to receive(:publish).and_return(failure_future)

      event_logger.clear
      context = create_context(data_future_ready, evt_handler: ev)
      event_logger.clear

      context.track("goal1", nil)
      context.close

      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::PUBLISH, instance_of(PublishEvent)
      ).once
    end
  end

  describe "custom field value type" do
    it "should return custom field value type" do
      context = create_context(data_future_ready)

      expect(context.custom_field_type("exp_test_ab", "country")).to eq("string")
      expect(context.custom_field_type("exp_test_ab", "overrides")).to eq("json")
    end
  end
end



class MockContextEventLoggerProxy < ContextEventLogger
  attr_accessor :called, :events, :logger

  def initialize
    @called = 0
    @events = []
    @logger = Logger.new(STDOUT)
  end

  def handle_event(event, data)
    @called += 1
    @events << { event: event, data: data }

    @logger.debug "event: #{event}"
    @logger.debug "data: #{data}"
  end

  def clear
    initialize
  end
end
