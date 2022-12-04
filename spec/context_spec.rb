# frozen_string_literal: true

require "byebug"
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
      Unit.new("user_id", "JfnnlDI7RTiF9RgfG2JNCw"),
      Unit.new("session_id", "pAE3a1i5Drs5mKRNq56adA"),
      Unit.new("email", "IuqYkNRfEx5yClel4j3NbA")
    ]
  }
  let(:clock) { Time.at(1620000000000 / 1000) }
  let(:clock_in_millis) { 1620000000000 }

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
  let(:event_logger) { instance_double(ContextEventLogger) }
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
  let(:scheduler) { instance_double(ScheduledExecutorService) }

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
    allow(client).to receive(:context_data).and_return(OpenStruct.new(exception: Exception.new("Failed"), success?: false, data_future: nil))
    client
  end

  def create_context(data_future = nil, config: nil, evt_handler: nil)
    if config.nil?
      config = ContextConfig.create
      config.set_units(units)
    end

    Context.create(clock, config, scheduler, data_future || data_future_ready, data_provider,
                   evt_handler || event_handler, event_logger, variable_parser, audience_matcher)
  end

  def create_ready_context(evt_handler: nil)
    config = ContextConfig.create
    config.set_units(units)

    Context.create(clock, config, scheduler, data_future_ready, data_provider,
                   evt_handler || event_handler, event_logger, variable_parser, audience_matcher)
  end

  def create_failed_context
    config = ContextConfig.create
    config.set_units(units)

    Context.create(clock, config, scheduler, data_future_failed, failed_data_provider,
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

  # it "calls event logger when ready" do
  #   context = create_ready_context
  #
  #   data_future.complete(data)
  #
  #   # context.waitUntilReady()
  #   expect(event_logger).to have_received(:handle_event).with(context, ContextEventLogger::EVENT_TYPE[:ready], data).once
  # end

  # it "callsEventLoggerWithCompletedFuture" do
  #   context = create_ready_context
  #   expect(event_logger).to have_received(:handle_event).with(context, ContextEventLogger::EVENT_TYPE[:ready], data).once
  # end

  # it "callsEventLoggerWithException" do
  #   context = create_context(data_future)
  #
  #   error = Exception.new("FAILED")
  #   data_future.completeExceptionally(error)
  #
  #   # context.waitUntilReady()
  #   expect(event_logger).to have_received(:handle_event).with(context, ContextEventLogger::EVENT_TYPE[:error], data).once
  # end

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
  end

  xit "getVariableValueCallsEventLogger" do
    context = create_ready_context

    context.variable_value("banner.border", nil)
    context.variable_value("banner.size", nil)

    exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
    ]

    expect(event_logger).to have_received(:handle_event).exactly(exposures.length).time

    # verify not called again with the same exposure
    context.variable_value("banner.border", nil)
    context.variable_value("banner.size", nil)

    expect(event_handler).to have_received(:handle_event).exactly(0).time
  end

  it "getVariableKeys" do
    context = create_context(refresh_data_future_ready)

    expect(variable_experiments).to eq(context.variable_keys)
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

  it "treatment" do
    context = create_ready_context

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

    context.close
  end

  it "treatmentReturnsOverrideVariant" do
    context = create_ready_context

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
    context = create_context(audience_data_future_ready)
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
  end

  xit "treatmentCallsEventLogger" do
    context = create_ready_context

    context.treatment("exp_test_ab")
    context.treatment("not_found")

    exposures = [
      Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
      Exposure.new(0, "not_found", nil, 0, clock_in_millis, false, true, false, false, false, false),
    ]

    expect(event_logger).to have_received(:handle_event).exactly(exposures.length).time

    # verify not called again with the same exposure
    # Mockito.clearInvocations(eventLogger)
    context.treatment("exp_test_ab")
    context.treatment("not_found")

    expect(event_logger).to have_received(:handle_event).exactly(0).time
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

  xit "publishCallsEventLogger" do
    #       context = create_ready_context
    #
    #       context.track("goal1", { amount: 125, hours: 245 })
    #
    #       Mockito.clearInvocations(eventLogger)
    #
    #       expected = PublishEvent.new
    #       expected.hashed = true
    #       expected.published_at = clock_in_millis
    #       expected.units = publish_units
    #
    #       expected.goals = [
    #         GoalAchievement.new("goal1", clock_in_millis,
    #                             new TreeMap<>({ amount: 125, hours: 245 })),
    #     }
    #
    #     when(event_handler.publish(context, expected)).thenReturn(CompletableFuture.completedFuture(nil))
    #
    #     context.publish
    #
    #     verify(eventLogger, times(1)).handleEvent(any(), any(), any())
    #     verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Publish, expected)
  end

  xit "publishCallsEventLoggerOnError" do
    #       context = create_ready_context
    #
    #       context.track("goal1", { amount: 125, hours: 245 })
    #
    #       Mockito.clearInvocations(eventLogger)
    #
    #       final Exception failure = new Exception("ERROR")
    #       when(event_handler.publish(any(), any())).thenReturn(CompletableFuture.failedFuture(failure))
    #
    #       final CompletionException actual = assertThrows(CompletionException.class, context::publish)
    #       assertSame(failure, actual.getCause())
    #
    #       verify(eventLogger, times(1)).handleEvent(any(), any(), any())
    #       verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Error, failure)
  end

  xit "publishResetsInternalQueuesAndKeepsAttributesOverridesAndCustomAssignments" do
    #       final ContextConfig config = ContextConfig.create()
    #                                                 .setUnits(units)
    #                                                 .set_attributes(mapOf(
    #                                                                  "attr1", "value1",
    #                                                                  "attr2", "value2"))
    #                                                 .setCustomAssignment("exp_test_abc", 3)
    #                                                 .set_override("not_found", 3))
    #
    #       context = create_context(config, data_futureReady)
    #
    #       expect(context.pending_count).to eq(0)
    #
    #       expect(context.treatment("exp_test_ab")).to eq(1)
    #       expect(3, context.treatment("exp_test_abc"))
    #       expect(3, context.treatment("not_found"))
    #       context.track("goal1", { amount: 125, hours: 245 })
    #
    #       expect(context.pending_count).to eq(4)
    #
    #       expected = PublishEvent.new
    #       expected.hashed = true
    #       expected.published_at = clock_in_millis
    #       expected.units = publish_units
    #
    #       expected.exposures = [
    #         Exposure.new(1, "exp_test_ab", "session_id", 1, clock_in_millis, true, true, false, false, false, false),
    #             Exposure.new(2, "exp_test_abc", "session_id", 3, clock_in_millis, true, true, false, false, true, false),
    #         Exposure.new(0, "not_found", nil, 3, clock_in_millis, false, true, true, false, false, false),
    #     }
    #
    #     expected.goals = [
    #       GoalAchievement.new("goal1", clock_in_millis,
    #                           new TreeMap<>({ amount: 125, hours: 245 })),
    #     }
    #
    #     expected.set_attributes( Attribute[)
    #       new Attribute("attr2", "value2", clock_in_millis),
    #           new Attribute("attr1", "value1", clock_in_millis),
    #     }
    #
    #     when(event_handler.publish(context, expected)).thenReturn(CompletableFuture.completedFuture(nil))
    #
    #     final CompletableFuture<Void> future = context.publishAsync()
    #     expect(context.pending_count).to eq(0)
    #     expect(3, context.custom_assignment("exp_test_abc"))
    #     expect(3, context.override("not_found"))
    #
    #     future.join()
    #     expect(context.pending_count).to eq(0)
    #     expect(3, context.custom_assignment("exp_test_abc"))
    #     expect(3, context.override("not_found"))
    #
    #     expect(event_handler).to have_received(:publish).once
    #
    #
    #     Mockito.clearInvocations(event_handler)
    #
    #     // repeat
    #     expect(context.treatment("exp_test_ab")).to eq(1)
    #     expect(3, context.treatment("exp_test_abc"))
    #     expect(3, context.treatment("not_found"))
    #     context.track("goal1", { amount: 125, hours: 245 })
    #
    #     expect(context.pending_count).to eq(1)
    #
    #     final PublishEvent expectedNext = new PublishEvent()
    #     expectedNext.hashed = true
    #     expectedNext.published_at = clock_in_millis
    #     expectedNext.units = publish_units
    #
    #     expectedNext.goals = [
    #       GoalAchievement.new("goal1", clock_in_millis,
    #                           new TreeMap<>({ amount: 125, hours: 245 })),
    #     }
    #
    #     expectedNext.set_attributes( Attribute[)
    #       new Attribute("attr2", "value2", clock_in_millis),
    #           new Attribute("attr1", "value1", clock_in_millis),
    #     }
    #
    #     when(event_handler.publish(context, expectedNext)).thenReturn(CompletableFuture.completedFuture(nil))
    #
    #     final CompletableFuture<Void> futureNext = context.publishAsync()
    #     expect(context.pending_count).to eq(0)
    #
    #     futureNext.join()
    #     expect(context.pending_count).to eq(0)
    #
    #     expect(event_handler).to have_received(:publish).once
    #     verify(event_handler, times(1)).publish(context, expectedNext)
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

    failure = Exception.new("FAILED")
    failure_future = OpenStruct.new(exception: Exception.new("FAILED"), success?: false)
    allow(ev).to receive(:publish).and_return(failure_future)
    actual = context.publish

    expect(actual.exception).to eq(failure)
    expect(ev).to have_received(:publish).once
  end

  xit "close" do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       context.track(" goal1 ", mapOf(" amount ", 125, " hours ", 245))
    #
    #       final CompletableFuture<Void> publish_future = new CompletableFuture<>()
    #       when(event_handler.publish(any(), any())).thenReturn(publish_future)
    #
    #       expect(context.closed?).to be_falsey
    #
    #       final Thread publisher = new Thread(() -> publish_future.complete(nil))
    #       publisher.start()
    #
    #       context.close
    #       publisher.join()
    #
    #       expect(context.closed?).to be_truthy
    #
    #       expect(event_handler).to have_received(:publish).once
    #
    #       context.close
  end

  xit " closeCallsEventLogger" do
    #       context = create_ready_context
    #
    #       Mockito.clearInvocations(eventLogger)
    #
    #       context.close
    #
    #       verify(eventLogger, times(1)).handleEvent(any(), any(), any())
    #       verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Close, nil)
  end

  xit "closeCallsEventLoggerWithPendingEvents" do
    #       context = create_ready_context
    #
    #       context.track(" goal1 ", mapOf(" amount ", 125, " hours ", 245))
    #
    #       Mockito.clearInvocations(eventLogger)
    #
    #       expected = PublishEvent.new
    #       expected.hashed = true
    #       expected.published_at = clock_in_millis
    #       expected.units = publish_units
    #
    #       expected.goals = [
    #         GoalAchievement.new(" goal1 ", clock_in_millis,
    #                             new TreeMap<>(mapOf(" amount ", 125, " hours ", 245))),
    #     }
    #
    #     final CompletableFuture<Void> publish_future = new CompletableFuture<>()
    #     when(event_handler.publish(any(), any())).thenReturn(publish_future)
    #
    #     final Thread publisher = new Thread(() -> publish_future.complete(nil))
    #     publisher.start()
    #
    #     context.close
    #     publisher.join()
    #
    #     verify(eventLogger, times(2)).handleEvent(any(), any(), any())
    #     verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Publish, expected)
    #     verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Close, nil)
  end

  xit " closeCallsEventLoggerOnError" do
    #       context = create_ready_context
    #
    #       context.track("goal1", { amount: 125, hours: 245 })
    #
    #       Mockito.clearInvocations(eventLogger)
    #
    #       final CompletableFuture<Void> publish_future = new CompletableFuture<>()
    #       when(event_handler.publish(any(), any())).thenReturn(publish_future)
    #
    #       final Exception failure = new Exception("FAILED")
    #       final Thread publisher = new Thread(() -> publish_future.completeExceptionally(failure))
    #       publisher.start()
    #
    #       final CompletionException actual = assertThrows(CompletionException.class, context::close)
    #       assertSame(failure, actual.getCause())
    #
    #       publisher.join()
    #
    #       verify(eventLogger, times(1)).handleEvent(any(), any(), any())
    #       verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Error, failure)
  end

  xit "closeExceptionally" do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       context.track(" goal1 ", mapOf(" amount ", 125, " hours ", 245))
    #
    #       final CompletableFuture<Void> publish_future = new CompletableFuture<>()
    #       when(event_handler.publish(any(), any())).thenReturn(publish_future)
    #
    #       final Exception failure = new Exception(" FAILED ")
    #       final Thread publisher = new Thread(() -> publish_future.completeExceptionally(failure))
    #       publisher.start()
    #
    #       final CompletionException actual = assertThrows(CompletionException.class, context::close)
    #       assertSame(failure, actual.getCause())
    #
    #       publisher.join()
    #
    #       expect(event_handler).to have_received(:publish).once
  end

  xit " refresh " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #       refreshdata_future.complete(refreshData)
    #
    #       context.refresh()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       final String[] experiments = Arrays.stream(refreshData.experiments).map(x -> x.name).toArray(String[]::new)
    #       assertArrayEquals(experiments, context.getExperiments())
  end

  xit " refreshCallsEventLogger " do
    #       context = create_ready_context
    #       Mockito.clearInvocations(eventLogger)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #       refreshdata_future.complete(refreshData)
    #
    #       context.refresh()
    #
    #       verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Refresh, refreshData)
  end

  xit " refreshCallsEventLoggerOnError " do
    #       context = create_ready_context
    #       Mockito.clearInvocations(eventLogger)
    #
    #       final Exception failure = new Exception(" ERROR ")
    #       when(dataProvider.getContextData()).thenReturn(CompletableFuture.failedFuture(failure))
    #       refreshdata_future.complete(refreshData)
    #
    #       final CompletionException actual = assertThrows(CompletionException.class, context::refresh)
    #       assertSame(failure, actual.getCause())
    #
    #       verify(eventLogger, times(1)).handleEvent(context, ContextEventLogger.EventType.Error, failure)
  end

  xit " refreshExceptionally " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #       expect(context.failed?).to be_falsey
    #
    #       context.track(" goal1 ", mapOf(" amount ", 125, " hours ", 245))
    #
    #       expect(context.pending_count).to eq(1)
    #
    #       final Exception failure = new Exception(" FAILED ")
    #       when(dataProvider.getContextData()).thenReturn(failedFuture(failure))
    #
    #       final CompletionException actual = assertThrows(CompletionException.class, context::refresh)
    #       assertSame(failure, actual.getCause())
    #
    #       verify(dataProvider, times(1)).getContextData()
  end

  xit " refreshKeepsAssignmentCacheWhenNotChanged " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       Arrays.stream(data.experiments).forEach(experiment -> context.treatment(experiment.name))
    #       context.treatment(" not_found ")
    #
    #       expect(data.experiments.length + 1, context.pending_count)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       Arrays.stream(refreshData.experiments).forEach(experiment -> context.treatment(experiment.name))
    #       context.treatment(" not_found ")
    #
    #       expect(refreshData.experiments.length + 1, context.pending_count)
  end

  xit " refreshKeepsAssignmentCacheWhenNotChangedOnAudienceMismatch " do
    #       context = create_context(audience_strict_data_future_ready)
    #
    #       expect(0, context.treatment(" exp_test_ab "))
    #
    #       expect(context.pending_count).to eq(1)
    #
    #       when(dataProvider.getContextData()).thenReturn(audience_strict_data_future_ready)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       refreshFuture.join()
    #
    #       expect(0, context.treatment(" exp_test_ab "))
    #
    #       expect(context.pending_count).to eq(1) // no Exposure.new
  end

  xit " refreshKeepsAssignmentCacheWhenNotChangedWithOverride " do
    #       context = create_ready_context
    #
    #       context.set_override(" exp_test_ab ", 3))
    #       expect(3, context.treatment(" exp_test_ab "))
    #
    #       expect(context.pending_count).to eq(1)
    #
    #       when(dataProvider.getContextData()).thenReturn(data_futureReady)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       refreshFuture.join()
    #
    #       expect(3, context.treatment(" exp_test_ab "))
    #
    #       expect(context.pending_count).to eq(1) // no Exposure.new
  end

  xit " refreshClearAssignmentCacheForStoppedExperiment " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_abc "
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       refreshData.experiments = Arrays.stream(refreshData.experiments).filter(x -> !x.name.equals(experiment_name))
    #       .toArray(Experiment[]::new)
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       expect(0, context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(3, context.pending_count) // stopped experiment triggered a Exposure.new
  end

  xit " refreshClearAssignmentCacheForStartedExperiment " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_new "
    #       expect(0, context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(3, context.pending_count) // stopped experiment triggered a Exposure.new
  end

  xit " refreshClearAssignmentCacheForFullOnExperiment " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_abc "
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       Arrays.stream(refreshData.experiments).filter(x -> x.name.equals(experiment_name)).forEach(experiment -> {
    #         expect(0, experiment.fullOnVariant)
    #         experiment.fullOnVariant = 1
    #         assertNotEquals(expected_variants.get(experiment.name), experiment.fullOnVariant)
    #       })
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       expect(1, context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(3, context.pending_count) // full-on experiment triggered a Exposure.new
  end

  xit " refreshClearAssignmentCacheForTrafficSplitChange " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_not_eligible "
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       Arrays.stream(refreshData.experiments).filter(x -> x.name.equals(experiment_name))
    #             .forEach(experiment -> experiment.trafficSplit = new double[]{0.0, 1.0})
    #
    #     refreshdata_future.complete(refreshData)
    #     refreshFuture.join()
    #
    #     expect(2, context.treatment(experiment_name))
    #     expect(0, context.treatment(" not_found "))
    #
    #     expect(3, context.pending_count) // newly eligible experiment triggered a Exposure.new
  end

  xit " refreshClearAssignmentCacheForIterationChange " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_abc "
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       Arrays.stream(refreshData.experiments).filter(x -> x.name.equals(experiment_name)).forEach(experiment -> {
    #         experiment.iteration = 2
    #         experiment.trafficSeedHi = 54870830
    #         experiment.trafficSeedLo = 398724581
    #         experiment.seedHi = 77498863
    #         experiment.seedLo = 34737352
    #       })
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       expect(2, context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(3, context.pending_count) // full-on experiment triggered a Exposure.new
  end

  xit " refreshClearAssignmentCacheForExperimentIdChange " do
    #       context = create_ready_context
    #       expect(context.ready?).to be_truthy
    #
    #       final String experiment_name = " exp_test_abc "
    #       expect(expected_variants.get(experiment_name), context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(context.pending_count).to eq(2)
    #
    #       when(dataProvider.getContextData()).thenReturn(refreshdata_future)
    #
    #       final CompletableFuture<Void> refreshFuture = context.refreshAsync()
    #
    #       verify(dataProvider, times(1)).getContextData()
    #
    #       Arrays.stream(refreshData.experiments).filter(x -> x.name.equals(experiment_name)).forEach(experiment -> {
    #         experiment.id = 11
    #         experiment.trafficSeedHi = 54870830
    #         experiment.trafficSeedLo = 398724581
    #         experiment.seedHi = 77498863
    #         experiment.seedLo = 34737352
    #       })
    #
    #       refreshdata_future.complete(refreshData)
    #       refreshFuture.join()
    #
    #       expect(2, context.treatment(experiment_name))
    #       expect(0, context.treatment(" not_found "))
    #
    #       expect(3, context.pending_count) // full-on experiment triggered a Exposure.new
  end
end
