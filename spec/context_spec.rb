# frozen_string_literal: true

require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "context_data_provider"
require "default_context_data_provider"
require "context_event_handler"
require "client"
require "client_config"
require "default_context_publisher"
require "default_http_client"
require "context_event_logger"
require "scheduled_executor_service"
require "audience_matcher"
require "json/unit"
require "logger"
require "timeout"

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
      "banner.border": ["exp_test_ab"],
      "banner.size": ["exp_test_ab"],
      "button.color": ["exp_test_abc"],
      "card.width": ["exp_test_not_eligible"],
      "submit.color": ["exp_test_fullon"],
      "submit.shape": ["exp_test_fullon"],
      "show-modal": ["exp_test_new"]
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
    ev = instance_double(Absmartly::ContextPublisher)
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

    expect { context.peek_treatment("exp_test_ab") }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.experiments }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.variable_value("banner.border", 17) }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.peek_variable_value("banner.border", 17) }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.variable_keys }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.custom_field_keys }.to raise_error(IllegalStateException, not_ready_message)
    expect { context.custom_field_value("exp_test_ab", "country") }.to raise_error(IllegalStateException, not_ready_message)

    expect {
      context.data
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
      context.set_unit("test", "test")
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_custom_assignment("exp_test_ab", 2)
    }.to raise_error(IllegalStateException, closed_message)

    expect {
      context.set_custom_assignments("exp_test_ab": 2)
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

    expect { context.peek_treatment("exp_test_ab") }.to raise_error(IllegalStateException, closed_message)
    expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException, closed_message)
    expect { context.variable_value("banner.border", 17) }.to raise_error(IllegalStateException, closed_message)
    expect { context.peek_variable_value("banner.border", 17) }.to raise_error(IllegalStateException, closed_message)
    expect { context.variable_keys }.to raise_error(IllegalStateException, closed_message)
    expect { context.custom_field_keys }.to raise_error(IllegalStateException, closed_message)
    expect { context.refresh }.to raise_error(IllegalStateException, closed_message)
    expect { context.experiments }.to raise_error(IllegalStateException, closed_message)
    expect { context.set_override("exp_test_ab", 2) }.to raise_error(IllegalStateException, closed_message)
    expect { context.set_overrides("exp_test_ab": 2) }.to raise_error(IllegalStateException, closed_message)
  end

  it "keeps experiments and overrides usable after finalize, like the JavaScript SDK" do
    context = create_ready_context
    allow(event_handler).to receive(:publish).and_return(nil)
    context.finalize

    closed_message = "ABSmartly Context is closed"
    expect(context.experiments).to eq(data.experiments.map(&:name))
    expect { context.set_override("exp_test_ab", 2) }.not_to raise_error
    expect { context.set_overrides("exp_test_ab": 2) }.not_to raise_error
    expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException, closed_message)
  end

  it "returns the event logger's result from close and a successful refresh, as in v1.3.0" do
    logger = Class.new(ContextEventLogger) do
      def handle_event(event, _data)
        "logged #{event}"
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    allow(data_provider).to receive(:context_data).and_return(data_future_ready)
    context = Context.create(clock, config, data_future_ready, data_provider, event_handler, logger,
                             variable_parser, audience_matcher)

    expect(context.refresh).to eq("logged refresh")
    expect(context.close).to eq("logged close")
    expect(context.close).to be_nil
  end

  it "returns the event logger's result from a failed refresh and keeps the data, as in v1.3.0" do
    logger = Class.new(ContextEventLogger) do
      def handle_event(event, data)
        "logged #{event} #{data}"
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, data_future_ready, data_provider, event_handler, logger,
                             variable_parser, audience_matcher)
    allow(data_provider).to receive(:context_data).and_return(failure_future)

    expect(context.refresh).to eq("logged error FAILED")
    expect(context.failed?).to be_falsey
  end

  it "close stops after one extra publish when a logger keeps queueing events" do
    config = ContextConfig.create
    config.set_units(units)
    holder = {}
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:context]&.track("again", nil) if event == ContextEventLogger::EVENT_TYPE::PUBLISH
      end
    end.new
    publishes = 0
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { publishes += 1; nil }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].close } }
      .to raise_error(StandardError, "Events queued while closing; retry close or finalize")
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to eq(1)
    expect(publishes).to eq(2)
  end

  it "retains events accepted during the last seal pass for a retry" do
    [:close, :finalize].each do |method|
      config = ContextConfig.create
      config.set_units(units)
      sent = []
      callbacks = 0
      holder = {}
      logger = Object.new
      logger.define_singleton_method(:handle_event) do |event, _data|
        if event == ContextEventLogger::EVENT_TYPE::PUBLISH && callbacks < 2
          callbacks += 1
          holder[:context].track("callback_#{callbacks}", nil)
        end
      end
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        sent.concat(event.goals.map(&:name))
        nil
      end
      context = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                               variable_parser, audience_matcher)
      holder[:context] = context
      context.track("initial", nil)
      expect { Timeout.timeout(5) { context.public_send(method) } }.to raise_error(StandardError, /retry/)
      expect(context.pending_count).to eq(1)
      expect(context.closed?).to be false
      Timeout.timeout(5) { context.public_send(method) }
      expect(sent).to eq(["initial", "callback_1", "callback_2"])
      expect(context.closed?).to be true
    end
  end

  it "publishes and refreshes before the context is ready, as in v1.3.0" do
    context = create_context(data_future)
    expect(context.ready?).to be_falsey
    expect { context.publish }.not_to raise_error
    allow(data_provider).to receive(:context_data).and_return(data_future_ready)
    expect { context.refresh }.not_to raise_error
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

  it "set unit keeps numeric uids as numbers" do
    context = create_ready_context
    context.set_unit("db_user_id", 125)
    context.set_unit("float_id", 125.75)
    expect(context.get_unit("db_user_id")).to eq(125)
    expect(context.get_unit("float_id")).to eq(125.75)
    expect(context.get_units[:db_user_id]).to eq(125)
  end

  it "numeric uid assigns and publishes like its to_s text, as in v1.3.0" do
    make = lambda do |uid|
      config = ContextConfig.create
      config.set_units(units.merge(session_id: uid))
      create_context(data_future_ready, config: config)
    end
    numeric = make.call(125.75)
    string = make.call("125.75")
    %w[exp_test_ab exp_test_abc exp_test_fullon].each do |name|
      expect(numeric.treatment(name)).to eq(string.treatment(name))
    end
    expect(VariantAssigner.new(125.0).key).to eq(VariantAssigner.new("125.0").key)
    expect(VariantAssigner.new(125.75).key).to eq(VariantAssigner.new("125.75").key)
    expect(VariantAssigner.new(125).key).to eq(VariantAssigner.new("125").key)
  end

  it "set unit converts symbols and string-like uids to strings, as in v1.3.0" do
    string_like = Class.new do
      def to_str
        "session-abc"
      end
    end
    context = create_ready_context
    context.set_unit("sym_id", :abc)
    context.set_unit("rack_id", string_like.new)
    expect(context.get_unit("sym_id")).to eq("abc")
    expect(context.get_unit("rack_id")).to eq("session-abc")
  end

  it "set unit rejects a nil uid as blank" do
    context = create_ready_context
    expect {
      context.set_unit("db_user_id", nil)
    }.to raise_error(IllegalStateException, "Unit 'db_user_id' UID must not be blank.")
  end

  it "set unit stores the to_s text of objects without to_str, as in v1.3.0" do
    # e.g. Rack::Session::SessionId or a UUID value object
    session_id = Class.new do
      def to_s
        " 4a9c0e1f "
      end
    end
    context = create_ready_context
    context.set_unit("rack_sid", session_id.new)
    expect(context.get_unit("rack_sid")).to eq("4a9c0e1f")
  end

  it "set unit rejects an object whose to_s is blank" do
    blank = Class.new do
      def to_s
        " "
      end
    end
    context = create_ready_context
    expect {
      context.set_unit("db_user_id", blank.new)
    }.to raise_error(IllegalStateException, "Unit 'db_user_id' UID must not be blank.")
  end

  it "passes a custom 1.3.0-style matcher the attribute keys the caller used" do
    seen = []
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen << attributes.keys
        Struct.new(:result).new(attributes[:age].to_i >= 20)
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: "prod")
    context.set_attribute(:age, 21)
    context.set_attribute("environment", "staging")

    expect(context.peek_treatment("exp_test_ab")).not_to eq(0)
    expect(seen.last).to contain_exactly(:age, "application", "environment")
    expect(seen.last.index("environment")).to be > seen.last.index(:age)
  end

  it "evaluates the last value set for a repeated attribute name" do
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, audience_matcher)
    context.set_attribute("age", 10)
    context.set_attribute("age", 25)

    expect(context.peek_treatment("exp_test_ab")).not_to eq(0)
  end

  it "keeps the system entry when a user attribute name is neither a String nor a Symbol" do
    seen = nil
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen = attributes
        Struct.new(:result).new(true)
      end
    end.new
    name = Object.new
    def name.to_s
      "environment"
    end
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: "prod")
    context.set_attribute(name, "staging")
    context.peek_treatment("exp_test_ab")

    expect(seen).to eq("application" => "website", "environment" => "prod", name => "staging")
  end

  describe "the built-in audience evaluator with an attribute set under both spellings" do
    def strict_context
      config = ContextConfig.create
      config.set_units(units)
      Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                     event_logger, variable_parser, audience_matcher)
    end

    it "uses the latest value on first resolution" do
      context = strict_context
      context.set_attribute("age", 10)
      context.set_attribute(:age, 25)
      expect(context.peek_treatment("exp_test_ab")).not_to eq(0)

      context = strict_context
      context.set_attribute("age", 25)
      context.set_attribute(:age, 10)
      expect(context.peek_treatment("exp_test_ab")).to eq(0)
    end

    it "uses the latest value when revalidating a cached assignment" do
      context = strict_context
      context.set_attribute("age", 10)
      expect(context.peek_treatment("exp_test_ab")).to eq(0)
      context.set_attribute(:age, 25)
      expect(context.peek_treatment("exp_test_ab")).not_to eq(0)
      context.set_attribute("age", 10)
      expect(context.peek_treatment("exp_test_ab")).to eq(0)
    end
  end

  it "passes both String and Symbol user keys to an AudienceMatcher subclass, as in v1.3.0" do
    seen = nil
    matcher = Class.new(AudienceMatcher) do
      define_method(:evaluate) do |audience, attributes|
        seen = attributes
        super(audience, attributes)
      end
    end.new(DefaultAudienceDeserializer.new)
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher)
    context.set_attribute("age", 10)
    context.set_attribute(:age, 25)
    context.peek_treatment("exp_test_ab")

    expect(seen).to eq("age" => 10, :age => 25)
  end

  it "allocates no more on warmed treatment and variable reads than one exposed read needs" do
    context = create_ready_context
    context.treatment("exp_test_ab")
    context.variable_value("banner.size", "default")
    measure = lambda do |&read|
      GC.disable
      before = GC.stat(:total_allocated_objects)
      100.times(&read)
      GC.stat(:total_allocated_objects) - before
    ensure
      GC.enable
    end
    expect(measure.call { context.treatment("exp_test_ab") }).to be <= 100
    expect(measure.call { context.variable_value("banner.size", "default") }).to be <= 100
  end

  it "lets a timeout interrupt a treatment waiting for the assignment lock" do
    release = Queue.new
    holding = Queue.new
    matcher = Class.new do
      define_method(:evaluate) do |_audience, _attributes|
        if Thread.current[:hold]
          holding << true
          # Bounded, so a regression that masks the wait fails instead of hanging.
          Timeout.timeout(1.5) { release.pop } rescue nil
        end
        Struct.new(:result).new(true)
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher)
    assignment = context.send(:assignment, "exp_test_abc")
    holder = Thread.new do
      Thread.current[:hold] = true
      context.peek_treatment("exp_test_ab")
    end
    begin
      Timeout.timeout(5) { holding.pop }
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { Timeout.timeout(0.3) { context.send(:claim_and_queue_exposure, assignment, "exp_test_abc") } }
        .to raise_error(Timeout::Error)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
    ensure
      release << true
      holder.join(5) || holder.kill
    end
  end

  it "keeps both String and Symbol user keys for a custom matcher, as in v1.3.0" do
    seen = nil
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen = attributes
        Struct.new(:result).new(attributes.fetch("age", 0) >= 20)
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: "prod")
    context.set_attribute("age", 21)
    context.set_attribute(:age, 22)
    context.set_attribute(:environment, "staging")

    expect(context.peek_treatment("exp_test_ab")).not_to eq(0)
    expect(seen).to eq("application" => "website", "age" => 21, :age => 22, :environment => "staging")
  end

  it "keeps a user String key when the same name is then set as a Symbol, as in v1.3.0" do
    seen = nil
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen = attributes
        Struct.new(:result).new(true)
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: "prod")
    context.set_attribute("environment", "a")
    context.set_attribute(:environment, "b")
    context.peek_treatment("exp_test_ab")

    expect(seen).to eq("application" => "website", "environment" => "a", :environment => "b")
    expect(seen.keys).to eq(["application", "environment", :environment])
  end

  it "keeps a user String key that reuses the configured value object when a Symbol key follows" do
    seen = nil
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen = attributes
        Struct.new(:result).new(attributes["environment"] == "prod")
      end
    end.new
    env = "prod"
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: env)
    context.set_attribute("environment", env)
    context.set_attribute(:environment, "staging")

    expect(context.peek_treatment("exp_test_ab")).not_to eq(0)
    expect(seen).to eq("application" => "website", "environment" => "prod", :environment => "staging")
  end

  it "publish returns normally when a logger's deferred close still has events queued" do
    config = ContextConfig.create
    config.set_units(units)
    holder = {}
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH

        holder[:context].track("again", nil)
        holder[:context].close unless holder[:closing]
        holder[:closing] = true
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish).and_return(nil)
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].publish } }.not_to raise_error
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to be > 0
  end

  it "closes on the next publish when a logger's deferred close hit the pass limit" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] = (holder[:events] || []) << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 3

        holder[:goals] += 1
        holder[:context].track("cb#{holder[:goals]}", nil)
        holder[:context].close if holder[:goals] == 1
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish).and_return(nil)
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be false
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end

  it "carries a deferred finalize as finalize, not close" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] = (holder[:events] || []) << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 3

        holder[:goals] += 1
        holder[:context].track("cb#{holder[:goals]}", nil)
        holder[:context].finalize if holder[:goals] == 1
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish).and_return(nil)
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be false
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].finalized?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(1)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(0)
    expect { holder[:context].set_override("exp_test_ab", 1) }.not_to raise_error
  end

  it "keeps a carried close when the next publish is rejected" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] = (holder[:events] || []) << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 3

        holder[:goals] += 1
        holder[:context].track("cb#{holder[:goals]}", nil)
        holder[:context].close if holder[:goals] == 1
      end
    end.new
    # Publishes 1-3 run inside the first publish (the close hits the pass
    # limit); the 4th is rejected and must not drop the carried close.
    responses = [nil, nil, nil, failure_future, nil]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    Timeout.timeout(5) { holder[:context].publish }
    holder[:context].track("late", nil)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to eq(2)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end

  it "a close from the error callback of a rejected publish seals on the next good publish" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        holder[:context].close if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]
        holder[:asked] = true if event == ContextEventLogger::EVENT_TYPE::ERROR
      end
    end.new
    responses = [StandardError.new("rejected"), nil]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect(Timeout.timeout(5) { holder[:context].publish }).to be_a(StandardError)
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to eq(1)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end

  it "a close requested from a publish callback during close stays within close's two passes" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0 }
    publishes = 0
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 10

        holder[:goals] += 1
        holder[:context].track("cb#{holder[:goals]}", nil)
        holder[:context].close
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { publishes += 1; nil }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].close } }
      .to raise_error(StandardError, "Events queued while closing; retry close or finalize")
    expect(publishes).to eq(2)
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to eq(1)
  end

  it "keeps a deferred finalize pending when its own publish is rejected" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0, events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 1

        holder[:goals] += 1
        holder[:context].track("cb", nil)
        holder[:context].finalize
      end
    end.new
    responses = [nil, failure_future, nil, nil]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].publish } }.to raise_error(Exception, "FAILED")
    expect(holder[:context].finalized?).to be false
    expect(holder[:context].pending_count).to eq(1)
    holder[:context].track("late", nil)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].finalized?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(1)
  end

  it "keeps a deferred finalize pending when a timeout interrupts its own publish" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0, events: [], calls: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 1

        holder[:goals] += 1
        holder[:context].track("followup", nil)
        holder[:context].finalize
      end
    end.new
    blocked = Queue.new
    handler = Object.new
    handler.define_singleton_method(:publish) do |_context, _event|
      holder[:calls] += 1
      if holder[:calls] == 2
        blocked << true
        sleep
      end
      OpenStruct.new(success?: true)
    end
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    # A real Timeout.timeout, which unwinds with a non-StandardError
    # (Timeout::ExitException) before surfacing as Timeout::Error.
    publisher = Thread.new { Timeout.timeout(0.5) { holder[:context].publish } }
    Timeout.timeout(5) { blocked.pop }
    expect { publisher.join(5) }.to raise_error(Timeout::Error)
    expect(holder[:context].finalized?).to be false
    expect(holder[:context].pending_count).to eq(1)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].finalized?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(1)
  end

  it "keeps a deferred finalize pending when its publishing thread is killed" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0, events: [], calls: 0 }
    blocked = Queue.new
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 1

        holder[:goals] += 1
        holder[:context].track("followup", nil)
        holder[:context].finalize
      end
    end.new
    handler = Object.new
    handler.define_singleton_method(:publish) do |_context, _event|
      holder[:calls] += 1
      if holder[:calls] == 2
        blocked << true
        sleep
      end
      OpenStruct.new(success?: true)
    end
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    publisher = Thread.new { holder[:context].publish }
    Timeout.timeout(5) { blocked.pop }
    publisher.kill
    publisher.join(5)
    expect(holder[:context].finalized?).to be false
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].finalized?).to be true
    expect(holder[:context].pending_count).to eq(0)
  end

  %i[timeout kill].each do |cancel|
    it "keeps a deferred finalize pending when #{cancel} lands after it is claimed, before it starts" do
      config = ContextConfig.create
      config.set_units(units)
      holder = { goals: 0, events: [] }
      logger = Class.new(ContextEventLogger) do
        define_method(:handle_event) do |event, _data|
          holder[:events] << event
          next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 1

          holder[:goals] += 1
          holder[:context].track("followup", nil)
          holder[:context].finalize
        end
      end.new
      handler = Object.new
      handler.define_singleton_method(:publish) { |_context, _event| OpenStruct.new(success?: true) }
      holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                        variable_parser, audience_matcher)
      holder[:context].track("goal1", nil)

      # Park the publisher on the line that starts the claimed seal.
      source = Context.instance_method(:flush).source_location.first
      handoff = File.readlines(source).index { |line| line.strip == "run_deferred_seal(claimed)" } + 1
      parked = Queue.new
      trace = TracePoint.new(:line) do |tp|
        if tp.path == source && tp.lineno == handoff && Thread.current[:gate]
          Thread.current[:gate] = false
          parked << true
          sleep
        end
      end
      trace.enable
      publisher = Thread.new do
        Thread.current[:gate] = true
        cancel == :timeout ? Timeout.timeout(5) { holder[:context].publish } : holder[:context].publish
      rescue Timeout::Error
        nil
      end
      begin
        Timeout.timeout(5) { parked.pop }
        cancel == :timeout ? publisher.raise(Timeout::Error) : publisher.kill
        publisher.join(5)
      ensure
        trace.disable
        publisher.join(1) || publisher.kill
      end

      expect(holder[:context].finalized?).to be false
      Timeout.timeout(5) { holder[:context].publish }
      expect(holder[:context].finalized?).to be true
      expect(holder[:context].pending_count).to eq(0)
      expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(1)
    end
  end

  it "a close requested after another thread's rejected publish waits for a later success" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        holder[:context].close if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked] && (holder[:asked] = true)
      end
    end.new
    calls = 0
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) do
      calls += 1
      calls == 2 ? failure_future : publish_future
    end
    context = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                             variable_parser, audience_matcher)
    holder[:context] = context
    # Pause thread A just after its successful publish releases the publish
    # lock, let thread B publish, be rejected and ask for close from the error
    # callback, then resume A. A's earlier success must not carry B's request.
    released = Queue.new
    resume = Queue.new
    pause_after_unlock = Class.new(Mutex) do
      define_method(:synchronize) do |&block|
        result = super(&block)
        if Thread.current[:role] == :a && !Thread.current[:paused]
          Thread.current[:paused] = true
          released << true
          resume.pop
        end
        result
      end
    end
    context.instance_variable_set(:@publish_mutex, pause_after_unlock.new)

    context.track("goal_a", nil)
    a = Thread.new do
      Thread.current[:role] = :a
      context.publish
    end
    Timeout.timeout(5) { released.pop }
    context.track("goal_b", nil)
    expect(Timeout.timeout(5) { context.publish }).to eq(failure_future)
    resume << true
    Timeout.timeout(5) { a.join }

    expect(context.closed?).to be false
    expect(context.pending_count).to eq(1)
    Timeout.timeout(5) { context.publish }
    expect(context.closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end

  it "a close requested from a publish callback during close is carried out by the next publish once close raises" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { goals: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:goals] < 2

        holder[:goals] += 1
        holder[:context].track("cb#{holder[:goals]}", nil)
        holder[:context].close
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish).and_return(nil)
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].close } }.to raise_error(StandardError, /retry close/)
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:context].pending_count).to eq(0)
  end

  it "keeps a close another thread requests while finalize waits for the publish lock" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    in_publish = Queue.new
    release = Queue.new
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]
          holder[:asked] = true
          holder[:context].close
        end
        holder[:context].track("cb", nil) if event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:produce]
      end
    end.new
    calls = 0
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) do
      calls += 1
      if calls == 1
        in_publish << true
        release.pop
        next failure_future
      end
      publish_future
    end
    context = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                             variable_parser, audience_matcher)
    holder[:context] = context
    context.track("goal_a", nil)
    # Thread A holds the publish lock; B starts finalize and waits for it. A's
    # publish is rejected and its error callback asks for close. B then hits
    # the pass bound and raises the retry error; A's request must survive.
    a = Thread.new { context.publish }
    Timeout.timeout(5) { in_publish.pop }
    holder[:produce] = true
    b = Thread.new do
      context.finalize
    rescue StandardError => e
      e
    end
    Timeout.timeout(5) { sleep 0.05 until b.status == "sleep" }
    release << true
    Timeout.timeout(5) { a.join }
    expect(Timeout.timeout(5) { b.value }).to be_a(StandardError)
    holder[:produce] = false

    Timeout.timeout(5) { context.publish }
    expect(context.closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(0)
  end

  it "matches the system entry's name exactly, not case-insensitively" do
    seen = nil
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen = attributes
        Struct.new(:result).new(true)
      end
    end.new
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, audience_strict_data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher, application: "website", environment: "prod")
    context.set_attribute("Environment", "staging")
    context.peek_treatment("exp_test_ab")

    expect(seen).to eq("application" => "website", "environment" => "prod", "Environment" => "staging")
  end

  it "a close requested from the error callback of a rejected finalize seals on the next good publish" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        holder[:context].close if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked] && (holder[:asked] = true)
      end
    end.new
    responses = [failure_future, publish_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].finalize } }.to raise_error(Exception, "FAILED")
    expect(holder[:context].closed?).to be false
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:context].pending_count).to eq(0)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end

  it "builds the attribute map with two allocations per call for String names" do
    config = ContextConfig.create
    config.set_units(units)
    context = Context.create(clock, config, data_future_ready, data_provider, event_handler, event_logger,
                             variable_parser, audience_matcher, application: "website", environment: "prod")
    10.times { |i| context.set_attribute("a#{i}", i) }
    context.send(:attributes_map)
    before = GC.stat(:total_allocated_objects)
    1000.times { context.send(:attributes_map) }
    expect(GC.stat(:total_allocated_objects) - before).to be < 2100
  end

  it "keeps a close carried from a rejected publish when a later finalize hits the pass bound" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { produce: false }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        (holder[:events] ||= []) << event
        holder[:context].close if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked] && (holder[:asked] = true)
        holder[:context].track("cb", nil) if event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:produce]
      end
    end.new
    responses = [failure_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift || publish_future }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)
    Timeout.timeout(5) { holder[:context].publish }
    holder[:produce] = true
    expect { Timeout.timeout(5) { holder[:context].finalize } }.to raise_error(StandardError, /retry close/)
    holder[:produce] = false
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end


  it "keeps a carried close when an explicit finalize is rejected" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        holder[:context].close if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked] && (holder[:asked] = true)
      end
    end.new
    responses = [failure_future, failure_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift || publish_future }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)
    Timeout.timeout(5) { holder[:context].publish }
    expect { Timeout.timeout(5) { holder[:context].finalize } }.to raise_error(Exception, "FAILED")
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end


  it "keeps a close requested from a publish callback when finalize's retry pass is rejected" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && !holder[:asked]

        holder[:asked] = true
        holder[:context].track("cb", nil)
        holder[:context].close
      end
    end.new
    responses = [publish_future, failure_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift || publish_future }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)
    expect { Timeout.timeout(5) { holder[:context].finalize } }.to raise_error(Exception, "FAILED")
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
  end


  it "carries the latest request when a callback asks for finalize then close" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [] }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        next unless event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]

        holder[:asked] = true
        holder[:context].finalize
        holder[:context].close
      end
    end.new
    responses = [failure_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift || publish_future }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    Timeout.timeout(5) { holder[:context].publish }
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(0)
  end

  it "a close requested while a deferred finalize fails replaces that finalize" do
    config = ContextConfig.create
    config.set_units(units)
    holder = { events: [], stage: 0 }
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        holder[:events] << event
        if event == ContextEventLogger::EVENT_TYPE::PUBLISH && holder[:stage].zero?
          holder[:stage] = 1
          holder[:context].track("cb", nil)
          holder[:context].finalize
        elsif event == ContextEventLogger::EVENT_TYPE::ERROR && holder[:stage] == 1
          holder[:stage] = 2
          holder[:context].close
        end
      end
    end.new
    # Publish 1 succeeds and its callback defers finalize; that finalize's own
    # publish is rejected and its error callback asks for close.
    responses = [publish_future, failure_future]
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) { responses.shift || publish_future }
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].publish } }.to raise_error(Exception, "FAILED")
    Timeout.timeout(5) { holder[:context].publish }
    expect(holder[:context].closed?).to be true
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
    expect(holder[:events].count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(0)
  end

  describe "overlapping seals and publishes" do
    # Every gate an example opens and every worker it starts, so a failing
    # assertion can't leave a worker blocked on a gate after the example.
    def gate
      (@gates ||= []) << Queue.new
      @gates.last
    end

    def worker(role = nil, &block)
      thread = Thread.new do
        Thread.current[:role] = role
        block.call
      end
      (@workers ||= []) << thread
      thread
    end

    after do
      Array(@gates).each { |q| 3.times { q << true } }
      stuck = Array(@workers).reject do |t|
        t.join(5) || (t.kill && t.join(5))
      end
      raise "#{stuck.size} worker thread(s) did not exit" unless stuck.empty?
    end

    def overlap_context(responses, logger)
      config = ContextConfig.create
      config.set_units(units)
      @sent = []
      handler = Object.new
      sent = @sent
      handler.define_singleton_method(:publish) do |_context, event|
        step = responses.shift
        step = step.call if step.respond_to?(:call)
        sent << [step.equal?(:ok) ? :ok : :rejected, (event.goals || []).map(&:name)]
        step.equal?(:ok) ? OpenStruct.new(success?: true) : OpenStruct.new(exception: Exception.new("FAILED"), success?: false)
      end
      Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                     variable_parser, audience_matcher)
    end

    def recording_logger(events, &block)
      Class.new(ContextEventLogger) do
        define_method(:handle_event) do |event, data|
          events << event
          block&.call(event, data)
        end
      end.new
    end

    # Pauses the calling thread after its seal's flush returns (before the seal
    # decides what to do with the result) until released.
    def pause_seal_after_flush(context, role, paused, release)
      original = context.method(:flush)
      allow(context).to receive(:flush) do |**kwargs|
        result = original.call(**kwargs)
        if kwargs[:sealing] && Thread.current[:role] == role && !Thread.current[:paused]
          Thread.current[:paused] = true
          paused << true
          release.pop
        end
        result
      end
    end

    it "close drops only the rejected batch, not goals tracked while it was in flight" do
      events = []
      in_flight = gate
      release = gate
      responses = [-> { in_flight << true; release.pop; :rejected }, :ok]
      context = overlap_context(responses, recording_logger(events))
      context.track("initial", nil)

      closer = worker { context.close }
      Timeout.timeout(5) { in_flight.pop }
      context.track("never_sent", nil)
      release << true
      Timeout.timeout(5) { closer.join }

      expect(@sent).to eq([[:rejected, ["initial"]], [:ok, ["never_sent"]]])
      expect(context.closed?).to be true
      expect(context.pending_count).to eq(0)
      expect(events.count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
    end

    it "an independent publish hands off a close requested by a finalize that is still failing" do
      events = []
      holder = {}
      logger = recording_logger(events) do |event, _data|
        if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]
          holder[:asked] = true
          holder[:context].close
        end
      end
      context = overlap_context([:rejected, :ok], logger)
      holder[:context] = context
      paused = gate
      release = gate
      pause_seal_after_flush(context, :a, paused, release)
      context.track("goal1", nil)

      a = worker(:a) do
        context.finalize
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      Timeout.timeout(5) { paused.pop }
      Timeout.timeout(5) { context.publish }
      expect(context.closed?).to be true
      release << true
      expect(Timeout.timeout(5) { a.value }.message).to eq("FAILED")

      expect(@sent).to eq([[:rejected, ["goal1"]], [:ok, ["goal1"]]])
      expect(events.count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
      expect(events.count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(0)
    end

    it "an empty publish hands off a close left pending after the queue was delivered" do
      events = []
      holder = {}
      logger = recording_logger(events) do |event, _data|
        if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]
          holder[:asked] = true
          holder[:context].close
        end
      end
      context = overlap_context([:rejected, :ok, :ok], logger)
      holder[:context] = context
      paused = gate
      release = gate
      pause_seal_after_flush(context, :a, paused, release)
      context.track("goal1", nil)

      # finalize is rejected and its error callback asks for close; while that
      # finalize is still unwinding, another publish delivers the queue, so
      # the close it hands off has nothing left to send.
      a = worker(:a) do
        context.finalize
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      Timeout.timeout(5) { paused.pop }
      allow(context).to receive(:take_close_pending).and_return(nil)
      Timeout.timeout(5) { context.publish }
      allow(context).to receive(:take_close_pending).and_call_original
      release << true
      Timeout.timeout(5) { a.join }
      expect(context.pending_count).to eq(0)
      expect(context.closed?).to be false

      Timeout.timeout(5) { context.publish }
      expect(context.closed?).to be true
      expect(events.count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
    end

    it "reports finalizing? only while a seal is running, across overlapping seals" do
      context = overlap_context([:ok], recording_logger([]))
      paused = gate
      release = gate
      pause_seal_after_flush(context, :a, paused, release)
      context.track("goal1", nil)
      expect(context.finalizing?).to be false

      a = worker(:a) do
        context.finalize
      end
      Timeout.timeout(5) { paused.pop }
      expect(context.finalizing?).to be true
      release << true
      Timeout.timeout(5) { a.join }
      expect(context.finalizing?).to be false
      expect(context.finalized?).to be true
    end


    it "stays finalizing? while a second seal runs after the first one raised" do
      first = gate
      second = gate
      calls = 0
      config = ContextConfig.create
      config.set_units(units)
      handler = Object.new
      handler.define_singleton_method(:publish) do |_c, _e|
        calls += 1
        if calls == 1
          first.pop
          next OpenStruct.new(exception: Exception.new("FAILED"), success?: false)
        end
        second.pop
        OpenStruct.new(success?: true)
      end
      context = Context.create(clock, config, data_future_ready, data_provider, handler, nil,
                               variable_parser, audience_matcher)
      context.track("goal1", nil)
      entered = gate
      original = context.method(:flush)
      allow(context).to receive(:flush) do |**kwargs|
        entered << Thread.current[:role] if kwargs[:sealing]
        original.call(**kwargs)
      end
      a = worker(:a) do
        context.finalize
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      Timeout.timeout(5) { entered.pop }
      b = worker(:b) do
        context.finalize
      end
      Timeout.timeout(5) { entered.pop }
      Timeout.timeout(5) { sleep 0.01 until b.status == "sleep" }
      first << true
      expect(Timeout.timeout(5) { a.value }.message).to eq("FAILED")
      expect(context.finalizing?).to be true
      second << true
      Timeout.timeout(5) { b.join }
      expect(context.finalizing?).to be false
      expect(context.finalized?).to be true
    end

    it "a seal's own empty pass leaves a pending close for a later publish" do
      events = []
      holder = {}
      logger = recording_logger(events) do |event, _data|
        if event == ContextEventLogger::EVENT_TYPE::ERROR && !holder[:asked]
          holder[:asked] = true
          holder[:context].close
        end
      end
      context = overlap_context([:rejected, :ok], logger)
      holder[:context] = context
      context.track("goal1", nil)

      # A publish is rejected and its error callback asks for close. The queue
      # is then delivered without handing the close off, so it stays pending.
      Timeout.timeout(5) { context.publish }
      allow(context).to receive(:take_close_pending).and_return(nil)
      Timeout.timeout(5) { context.publish }
      allow(context).to receive(:take_close_pending).and_call_original
      expect(context.pending_count).to eq(0)
      expect(context.instance_variable_get(:@close_pending)).to eq(ContextEventLogger::EVENT_TYPE::CLOSE)

      # A seal's own empty pass, paused before it decides: it must neither
      # claim nor drop the pending close, which the publish below still sees.
      paused = gate
      release = gate
      pause_seal_after_flush(context, :a, paused, release)
      a = worker(:a) do
        context.finalize
      end
      begin
        Timeout.timeout(5) { paused.pop }
        expect(context.instance_variable_get(:@close_pending)).to eq(ContextEventLogger::EVENT_TYPE::CLOSE)
        Timeout.timeout(5) { context.publish }
        expect(context.closed?).to be true
        expect(context.instance_variable_get(:@sealed_by)).to eq(ContextEventLogger::EVENT_TYPE::CLOSE)
      ensure
        release << true
        a.join(5) || a.kill
      end
      expect(events.select { |e| [ContextEventLogger::EVENT_TYPE::CLOSE, ContextEventLogger::EVENT_TYPE::FINALIZE].include?(e) })
        .to eq([ContextEventLogger::EVENT_TYPE::CLOSE])
    end

    it "a failed older deferred finalize does not override a newer close already handed off" do
      events = []
      holder = {}
      logger = recording_logger(events) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH

        holder[:publishes] = (holder[:publishes] || 0) + 1
        if holder[:publishes] == 1
          holder[:context].track("cb1", nil)
          holder[:context].finalize
        elsif Thread.current[:role] == :b
          holder[:context].close
        end
      end
      # Publish 1 (thread A) succeeds and defers finalize. That finalize's own
      # publish is rejected; before it re-arms itself, thread B publishes
      # successfully, asks for close and claims it. A's failure must not then
      # restore the older finalize, which an empty publish would carry out
      # before B's newer close.
      context = overlap_context([:ok, :rejected, :ok, :ok], logger)
      holder[:context] = context
      paused = gate
      release = gate
      claimed = gate
      resume_b = gate
      original_seal = context.method(:seal)
      allow(context).to receive(:seal) do |event_type|
        original_seal.call(event_type)
      rescue Exception # rubocop:disable Lint/RescueException
        if Thread.current[:role] == :a && !Thread.current[:paused]
          Thread.current[:paused] = true
          paused << true
          release.pop
        end
        raise
      end
      original_run = context.method(:run_deferred_seal)
      allow(context).to receive(:run_deferred_seal) do |claim|
        if Thread.current[:role] == :b && !Thread.current[:paused]
          Thread.current[:paused] = true
          claimed << true
          resume_b.pop
        end
        original_run.call(claim)
      end
      context.track("goal1", nil)

      a = worker(:a) do
        context.publish
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      b = nil
      begin
        Timeout.timeout(5) { paused.pop }
        context.track("goal_b", nil)
        b = worker(:b) do
          context.publish
        end
        Timeout.timeout(5) { claimed.pop }
        release << true
        expect(Timeout.timeout(5) { a.value }.message).to eq("FAILED")
        # An empty publish before B carries out its claimed close: it must not
        # find A's older finalize restored and seal with it.
        Timeout.timeout(5) { context.publish }
        resume_b << true
        Timeout.timeout(5) { b.join }
      ensure
        release << true
        resume_b << true
        [a, b].compact.each { |t| t.join(5) || t.kill }
      end

      expect(context.closed?).to be true
      expect(events.count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(1)
      expect(events.count(ContextEventLogger::EVENT_TYPE::FINALIZE)).to eq(0)
    end

    it "a second finalize is not turned into a close by a failing first one" do
      events = []
      holder = {}
      logger = recording_logger(events) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && !holder[:asked]

        holder[:asked] = true
        holder[:context].track("followup", nil)
        holder[:context].close
      end
      context = overlap_context([:rejected, :ok, :rejected], logger)
      holder[:context] = context
      paused = gate
      release = gate
      pause_seal_after_flush(context, :a, paused, release)
      context.track("goal1", nil)

      a = worker(:a) do
        context.finalize
      rescue Exception => e # rubocop:disable Lint/RescueException
        e
      end
      Timeout.timeout(5) { paused.pop }
      expect { Timeout.timeout(5) { context.finalize } }.to raise_error(Exception, "FAILED")
      release << true
      expect(Timeout.timeout(5) { a.value }.message).to eq("FAILED")

      expect(context.closed?).to be false
      expect(context.pending_count).to eq(1)
      expect(@sent.last).to eq([:rejected, ["followup"]])
      expect(events.count(ContextEventLogger::EVENT_TYPE::CLOSE)).to eq(0)
    end
  end

  it "a deferred close still raises a publisher error from its own publish" do
    config = ContextConfig.create
    config.set_units(units)
    holder = {}
    calls = 0
    logger = Class.new(ContextEventLogger) do
      define_method(:handle_event) do |event, _data|
        next unless event == ContextEventLogger::EVENT_TYPE::PUBLISH && !holder[:done]

        holder[:done] = true
        holder[:context].track("again", nil)
        holder[:context].close
      end
    end.new
    handler = instance_double(Absmartly::ContextPublisher)
    allow(handler).to receive(:publish) do
      calls += 1
      raise IOError, "collector down" if calls > 1

      nil
    end
    holder[:context] = Context.create(clock, config, data_future_ready, data_provider, handler, logger,
                                      variable_parser, audience_matcher)
    holder[:context].track("goal1", nil)

    expect { Timeout.timeout(5) { holder[:context].publish } }.to raise_error(IOError, "collector down")
    expect(holder[:context].closed?).to be false
    expect(holder[:context].pending_count).to eq(1)
  end

  it "does not let an overridden public getter change matcher attributes" do
    seen = []
    matcher = Class.new do
      define_method(:evaluate) do |_audience, attributes|
        seen << attributes.dup
        Struct.new(:result).new(true)
      end
    end.new
    config = ContextConfig.create
    config.set_unit(:session_id, "alice")
    config.set_attribute(:country, "US")
    context = Context.create(clock, config, data_future_ready, data_provider, event_handler,
                             event_logger, variable_parser, matcher)
    context.define_singleton_method(:get_attributes) { { bad: "override" } }
    context.experiments.each { |name| context.peek_treatment(name) }

    expect(seen).not_to be_empty
    expect(seen).to all(include(country: "US"))
    expect(seen.any? { |attributes| attributes.key?(:bad) }).to be false
  end

  it "set_unit returns the stored UID, as in v1.3.0" do
    context = create_ready_context
    expect(context.set_unit("extra_id", " padded ")).to eq("padded")
    expect(context.set_unit("num_id", 42)).to eq("42")
    expect(context.set_unit("num_id", "42")).to eq("42")
    expect(context.set_unit(:extra_id, "padded")).to eq("padded")
  end

  it "skips revalidation on warmed reads of an experiment with no rules or audience" do
    context = create_ready_context
    context.treatment("exp_test_ab")
    context.set_attribute("age", 30)
    calls = 0
    allow(context).to receive(:attributes_map).and_wrap_original { |m| calls += 1; m.call }
    allow(context).to receive(:audience_matches).and_wrap_original { |m, *args| calls += 1; m.call(*args) }

    5.times { context.treatment("exp_test_ab") && context.peek_treatment("exp_test_ab") }
    expect(calls).to eq(0)
  end

  it "accepts the same unit again as a String or a number, as in v1.3.0" do
    context = create_ready_context
    context.set_unit("db_id", 123456)
    expect { context.set_unit("db_id", "123456") }.not_to raise_error
    expect { context.set_unit(:db_id, " 123456 ") }.not_to raise_error
    expect(context.get_unit(:db_id)).to eq(123456)
    expect { context.set_unit("db_id", "654321") }.to raise_error(IllegalStateException, "Unit 'db_id' already set.")
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

  it "returns control once the override of an unknown experiment is cleared" do
    context = create_ready_context
    context.set_override("exp_test_new", 3)
    expect(context.treatment("exp_test_new")).to eq(3)

    context.set_override("exp_test_new", nil)
    expect(context.treatment("exp_test_new")).to eq(0)
    expect(context.treatment("exp_test_new")).to eq(0)
    expect(context.pending_count).to eq(2)
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

  it "flags custom on the exposure when a peeked variant equals the new custom assignment" do
    context = create_ready_context
    expect(context.peek_treatment("exp_test_abc")).to eq(2)

    context.set_custom_assignment("exp_test_abc", 2)
    expect(context.treatment("exp_test_abc")).to eq(2)

    expect(event_handler).to receive(:publish) do |_ctx, event|
      expect(event.exposures.map(&:custom)).to eq([true])
      publish_future
    end
    context.publish
  end

  it "keeps an exposed assignment when the custom assignment equals its variant" do
    context = create_ready_context
    expect(context.treatment("exp_test_abc")).to eq(2)

    context.set_custom_assignment("exp_test_abc", 2)
    expect(context.treatment("exp_test_abc")).to eq(2)
    expect(context.pending_count).to eq(1)
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

    variable_experiments.each do |variable, experiment_names|
      actual = context.peek_variable_value(variable, 17)
      experiment_name = experiment_names.first
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

    variable_experiments.each do |variable, experiment_names|
      actual = context.variable_value(variable, 17)
      experiment_name = experiment_names.first
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

    expect(context.variable_keys).to eq(variable_experiments.transform_values(&:first))
    expect(context.variable_keys[:"banner.border"]).to eq("exp_test_ab")
  end

  it "variable_keys_list lists every experiment for each key" do
    context = create_context(refresh_data_future_ready)

    expect(context.variable_keys_list).to eq(variable_experiments)
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

    data = { "123":  1, "456": 0 }
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

  it "reads a custom field with a missing or null type as untyped text" do
    raw = JSON.parse(json)
    fields = raw["experiments"].find { |e| e["name"] == "exp_test_ab" }["customFieldValues"]
    fields << { "name" => "untyped", "value" => "x" } << { "name" => "null_type", "value" => "y", "type" => nil }
    payload = JSON.generate(raw)
    context = create_context(client_mock(descr.deserialize(payload, 0, payload.length)).context_data)

    expect(context.ready?).to be true
    expect(context.failed?).to be false
    expect(context.custom_field_value("exp_test_ab", "untyped")).to eq("x")
    expect(context.custom_field_type("exp_test_ab", "untyped")).to be_nil
    expect(context.custom_field_value("exp_test_ab", "null_type")).to eq("y")
    expect(context.custom_field_value("exp_test_ab", "country")).to eq("US,PT,ES,DE,FR")
  end

  it "reads a custom field with a missing or null type as untyped text after a refresh" do
    raw = JSON.parse(json)
    fields = raw["experiments"].find { |e| e["name"] == "exp_test_ab" }["customFieldValues"]
    fields << { "name" => "untyped", "value" => "x" } << { "name" => "null_type", "value" => "y", "type" => nil }
    payload = JSON.generate(raw)
    untyped_provider = DefaultContextDataProvider.new(client_mock(descr.deserialize(payload, 0, payload.length)))
    context = create_context(data_future_ready, dt_provider: untyped_provider)

    expect { context.refresh }.not_to raise_error
    expect(context.failed?).to be false
    expect(context.custom_field_value("exp_test_ab", "untyped")).to eq("x")
    expect(context.custom_field_type("exp_test_ab", "untyped")).to be_nil
    expect(context.custom_field_value("exp_test_ab", "null_type")).to eq("y")
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

  it "track rejects non-object properties" do
    context = create_ready_context
    [[1, 2], "x", 5, true].each do |props|
      expect { context.track("goal1", props) }.to raise_error(ArgumentError, "Goal 'goal1' properties must be of type object.")
    end
    expect(context.pending_count).to eq(0)
  end

  it "track accepts hash-like properties through to_h, e.g. ActionController::Parameters" do
    params = Class.new do
      def to_h
        { "amount" => 3 }
      end
    end
    context = create_ready_context
    context.track("goal1", params.new)
    expect(context.instance_variable_get(:@achievements).last.properties).to eq({ "amount" => 3 })
  end

  it "track prefers to_unsafe_h, so unpermitted ActionController::Parameters don't raise" do
    params = Class.new do
      def to_h
        raise "ActionController::UnfilteredParameters"
      end

      def to_unsafe_h
        { "amount" => 4 }
      end
    end
    context = create_ready_context
    context.track("goal1", params.new)
    expect(context.instance_variable_get(:@achievements).last.properties).to eq({ "amount" => 4 })
  end

  it "track copies properties" do
    context = create_ready_context
    props = { amount: 1 }
    context.track("goal1", props)
    props[:amount] = 2
    expect(context.instance_variable_get(:@achievements).last.properties).to eq({ amount: 1 })
  end

  it "trackQueuesWhenNotReady" do
    context = create_context(data_future)

    context.track("goal1", { amount: 125, hours: 245 })
    context.track("goal2", { tries: 7 })
    context.track("goal3", nil)

    expect(context.pending_count).to eq(3)
  end

  describe "a handler that mutates the payload it accepted" do
    def mutating_handler(sent, response, during_first: nil)
      handler = Object.new
      handler.define_singleton_method(:publish) do |context, event|
        sent << [(event.goals || []).map(&:name), (event.exposures || []).map(&:name)]
        during_first&.call(context) if sent.size == 1
        event.goals&.clear
        event.exposures&.clear
        response
      end
      handler
    end

    it "does not leave accepted events queued or send them again" do
      sent = []
      context = create_ready_context(evt_handler: mutating_handler(sent, OpenStruct.new(success?: true)))
      context.track("order", nil)
      context.treatment("exp_test_ab")
      context.publish

      expect(context.pending_count).to eq(0)
      context.publish
      expect(sent).to eq([[["order"], ["exp_test_ab"]]])
    end

    it "close still drops only the rejected batch it sent" do
      sent = []
      queue_later = ->(context) { context.track("queued_meanwhile", nil) }
      context = create_ready_context(evt_handler: mutating_handler(sent, OpenStruct.new(success?: false),
                                                                   during_first: queue_later))
      context.track("order", nil)
      context.close

      expect(sent).to eq([[["order"], []], [["queued_meanwhile"], []]])
      expect(context.pending_count).to eq(0)
    end
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

    expect(event_logger).not_to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::PUBLISH, anything)
    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED").once
    expect(event_handler).to have_received(:publish).with(context, expected).once

    allow(event_handler).to receive(:publish).and_return(nil)
    context.publish
    expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::PUBLISH, expected).once
  end

  it "a close from the error callback of a failed publish does not retry the batch" do
    calls = 0
    handler = Object.new
    handler.define_singleton_method(:publish) { |_c, _e| calls += 1; StandardError.new("delivery failed") }
    logger = Object.new
    ctx = nil
    logger.define_singleton_method(:handle_event) { |type, _d| ctx.close if type == ContextEventLogger::EVENT_TYPE::ERROR && calls < 50 }
    config = ContextConfig.create
    config.set_units(units)
    ctx = Context.create(clock, config, data_future_ready, data_provider, handler, logger, variable_parser, audience_matcher)
    ctx.track("goal1", nil)

    expect(ctx.publish).to be_a(StandardError)
    expect(calls).to eq(1)
    expect(ctx.pending_count).to eq(1)
    expect(ctx.closed?).to be false
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
    ev = instance_double(Absmartly::ContextPublisher)
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

      # A failed refresh keeps the current data; only the initial fetch fails a context.
      expect(context.failed?).to be_falsey
      expect(context.treatment("exp_test_ab")).to eq(expected_variants[:exp_test_ab])
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
      expect(context.failed?).to be_falsey
    end

    it "does not refresh when context already failed" do
      context = create_failed_context
      expect(context.failed?).to be_truthy

      initial_data = context.data
      expect(context.refresh).to be_nil

      expect(context.data).to eq(initial_data)
      expect(context.failed?).to be_truthy
    end

    it "updates data on successful refresh" do
      context = create_context(data_future_ready, dt_provider: refresh_data_provider)

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
      ev = instance_double(Absmartly::ContextPublisher)
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
      ev = instance_double(Absmartly::ContextPublisher)
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

    it "reports a failed HTTP publish to the error callback only, without writing to stderr" do
      client_config = ClientConfig.create.tap do |c|
        c.endpoint = "https://localhost/v1"
        c.api_key = "k"
        c.application = "a"
        c.environment = "e"
      end
      http_client = instance_double(DefaultHttpClient)
      allow(http_client).to receive(:put)
        .and_return(DefaultHttpClient.default_response(500, "Internal Server Error", nil, nil))
      publisher = Absmartly::DefaultContextPublisher.new(Client.new(client_config, http_client))
      context = create_ready_context(evt_handler: publisher)
      context.track("goal1", nil)

      expect { context.publish }.not_to output.to_stderr
      expect(http_client).to have_received(:put).once
      expect(event_logger).to have_received(:handle_event)
        .with(ContextEventLogger::EVENT_TYPE::ERROR, "Internal Server Error").once
      expect(event_logger).not_to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::PUBLISH, anything)
      expect(context.pending_count).to eq(1)
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
      ev = instance_double(Absmartly::ContextPublisher)
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

    it "close logs a rejected final publish and seals, as in v1.3.0" do
      ev = instance_double(Absmartly::ContextPublisher)
      allow(ev).to receive(:publish).and_return(failure_future)
      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)
      expect(context.pending_count).to eq(1)

      expect { context.close }.not_to raise_error
      expect(context.closed?).to be true
      expect(context.pending_count).to eq(0)
      expect(ev).to have_received(:publish).once
      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::ERROR, "FAILED").once
      expect(event_logger).to have_received(:handle_event).with(ContextEventLogger::EVENT_TYPE::CLOSE, nil).once
    end

    it "close re-raises a publisher that raises and stays open with the events queued" do
      ev = instance_double(Absmartly::ContextPublisher)
      allow(ev).to receive(:publish).and_raise(StandardError, "boom")
      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)

      expect { context.close }.to raise_error(StandardError, "boom")
      expect(context.closed?).to be false
      expect(context.pending_count).to eq(1)

      allow(ev).to receive(:publish).and_return(nil)
      expect { context.close }.not_to raise_error
      expect(context.closed?).to be true
      expect(context.pending_count).to eq(0)
    end

    it "finalize raises a rejected final publish, stays open with events queued, and a second finalize seals" do
      ev = instance_double(Absmartly::ContextPublisher)
      allow(ev).to receive(:publish).and_return(failure_future)
      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)

      expect { context.finalize }.to raise_error(Exception, "FAILED")
      expect(context.closed?).to be false
      expect(context.pending_count).to eq(1)

      allow(ev).to receive(:publish).and_return(nil)
      expect(context.finalize).to be_nil
      expect(context.closed?).to be true
      expect(context.pending_count).to eq(0)
      expect(ev).to have_received(:publish).twice
    end

    it "finalize keeps a StandardError instance and wraps a bare Exception with its cause" do
      [StandardError.new("rejected"), Exception.new("rejected")].each do |failure|
        ev = instance_double(Absmartly::ContextPublisher)
        allow(ev).to receive(:publish).and_return(failure)
        context = create_ready_context(evt_handler: ev)
        context.track("goal1", nil)
        expect { context.finalize }.to raise_error(StandardError, "rejected") do |error|
          expect(failure.is_a?(StandardError) ? error : error.cause).to equal(failure)
        end
        expect(context.closed?).to be false
        expect(context.pending_count).to eq(1)
      end
    end

    it "finalize raises the publish failure and leaves the context open" do
      ev = instance_double(Absmartly::ContextPublisher)
      allow(ev).to receive(:publish).and_return(failure_future)
      context = create_ready_context(evt_handler: ev)
      context.track("goal1", nil)

      expect { context.finalize }.to raise_error(Exception, "FAILED")
      expect(context.closed?).to be false
      expect(context.pending_count).to eq(1)

      allow(ev).to receive(:publish).and_return(nil)
      expect(context.finalize).to be_nil
      expect(context.closed?).to be true
    end
  end

  describe "unit management" do
    it "should set a unit" do
      context = create_ready_context

      context.set_unit("db_user_id", "new_uid")

      units_ivar = context.instance_variable_get(:@units)
      expect(units_ivar[:db_user_id]).to eq("new_uid")
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
      ev = instance_double(Absmartly::ContextPublisher)
      allow(ev).to receive(:publish).and_return(failure_future)

      event_logger.clear
      context = create_context(data_future_ready, evt_handler: ev)
      event_logger.clear

      context.track("goal1", nil)
      expect { context.close }.not_to raise_error

      expect(event_logger).to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::ERROR, "FAILED"
      ).once
      expect(event_logger).not_to have_received(:handle_event).with(
        ContextEventLogger::EVENT_TYPE::PUBLISH, anything
      )
      expect(context.closed?).to be true
    end
  end

  describe "custom field value type" do
    it "should return custom field value type" do
      context = create_context(data_future_ready)

      expect(context.custom_field_type("exp_test_ab", "country")).to eq("string")
      expect(context.custom_field_type("exp_test_ab", "overrides")).to eq("json")
    end

    it "reads a custom field with a missing or null type as text instead of failing the context" do
      raw = { experiments: [{ id: 1, name: "exp_types", unitType: "session_id", iteration: 1, seedHi: 1, seedLo: 2,
                              split: [0.5, 0.5], trafficSeedHi: 3, trafficSeedLo: 4, trafficSplit: [0, 1],
                              fullOnVariant: 0, variants: [{ name: "A", config: nil }, { name: "B", config: nil }],
                              customFieldValues: [{ name: "missing", value: "x" }, { name: "null", value: "1", type: nil },
                                                  { name: "number", value: "7", type: "number" }] }] }.to_json
      parsed = DefaultContextDataDeserializer.new.deserialize(raw, 0, raw.size)
      context = create_context(OpenStruct.new(data_future: parsed, success?: true))

      expect(context.ready?).to be true
      expect(context.custom_field_value("exp_types", "missing")).to eq("x")
      expect(context.custom_field_type("exp_types", "missing")).to be_nil
      expect(context.custom_field_value("exp_types", "null")).to eq("1")
      expect(context.custom_field_value("exp_types", "number")).to eq(7)
    end
  end

  describe "get_unit" do
    it "returns the uid for a given unit type" do
      context = create_ready_context
      expect(context.get_unit(:session_id)).to eq("e791e240fcd3df7d238cfc285f475e8152fcc0ec")
      expect(context.get_unit(:user_id)).to eq("123456789")
      expect(context.get_unit(:email)).to eq("bleh@absmartly.com")
    end

    it "returns nil for unknown unit type" do
      context = create_ready_context
      expect(context.get_unit(:nonexistent)).to be_nil
    end
  end

  describe "get_units" do
    it "returns a copy of all units" do
      context = create_ready_context
      result = context.get_units()
      expect(result[:session_id]).to eq("e791e240fcd3df7d238cfc285f475e8152fcc0ec")
      expect(result[:user_id]).to eq("123456789")
      expect(result[:email]).to eq("bleh@absmartly.com")
    end
  end

  describe "get_attribute" do
    it "returns the last set value for a given attribute name" do
      context = create_ready_context
      context.set_attribute("country", "US")
      context.set_attribute("language", "en")
      context.set_attribute("country", "DE")

      expect(context.get_attribute("country")).to eq("DE")
      expect(context.get_attribute("language")).to eq("en")
    end

    it "returns nil for unknown attribute" do
      context = create_ready_context
      expect(context.get_attribute("nonexistent")).to be_nil
    end
  end

  describe "get_attributes" do
    it "returns a hash of all attributes with last value for each key" do
      context = create_ready_context
      context.set_attribute("country", "US")
      context.set_attribute("language", "en")
      context.set_attribute("country", "DE")

      result = context.get_attributes()
      expect(result["country"]).to eq("DE")
      expect(result["language"]).to eq("en")
    end
  end

  describe "ready_error" do
    it "returns nil when context is ready without error" do
      context = create_ready_context
      expect(context.ready_error).to be_nil
    end

    it "returns the exception when context failed" do
      context = create_failed_context
      expect(context.ready_error).not_to be_nil
      expect(context.ready_error.message).to eq("FAILED")
    end
  end

  describe "finalizing?" do
    it "returns false when context is not closing" do
      context = create_ready_context
      expect(context.finalizing?).to be_falsey
    end

    it "returns false when context is fully closed" do
      context = create_ready_context
      context.close
      expect(context.finalizing?).to be_falsey
      expect(context.closed?).to be_truthy
    end
  end

  describe "read methods raise when not ready" do
    let(:not_ready_message) { "ABSmartly Context is not yet ready" }

    it "raises for treatment, peek and variable reads" do
      context = create_context(data_future)
      expect(context.ready?).to be_falsey
      expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.peek_treatment("exp_test_ab") }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.variable_value("banner.border", 17) }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.peek_variable_value("banner.border", 17) }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.experiments }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.variable_keys }.to raise_error(IllegalStateException, not_ready_message)
      expect { context.custom_field_keys }.to raise_error(IllegalStateException, not_ready_message)
      expect(context.pending_count).to eq(0)
    end

    it "still queues goals before ready" do
      context = create_context(data_future)
      context.track("goal1", nil)
      expect(context.pending_count).to eq(1)
    end
  end

  describe "read methods raise when closed" do
    it "raises for treatment, peek and variable reads" do
      context = create_ready_context
      context.close
      closed_message = "ABSmartly Context is closed"
      expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException, closed_message)
      expect { context.peek_treatment("exp_test_ab") }.to raise_error(IllegalStateException, closed_message)
      expect { context.variable_value("banner.border", 17) }.to raise_error(IllegalStateException, closed_message)
      expect { context.peek_variable_value("banner.border", 17) }.to raise_error(IllegalStateException, closed_message)
      expect { context.variable_keys }.to raise_error(IllegalStateException, closed_message)
      expect { context.custom_field_keys }.to raise_error(IllegalStateException, closed_message)
      expect { context.custom_field_value("exp_test_ab", "country") }.to raise_error(IllegalStateException, closed_message)
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
