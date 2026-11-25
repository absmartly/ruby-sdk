# frozen_string_literal: true

require "a_b_smartly"
require "a_b_smartly_config"
require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "context_data_provider"
require "default_context_data_provider"
require "context_event_handler"
require "context_event_logger"
require "audience_matcher"
require "json/unit"
require "json"
require "logger"
require "timeout"

RSpec.describe "create_context_async" do
  let(:units) {
    {
      session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec",
      user_id: "123456789",
      email: "bleh@absmartly.com"
    }
  }
  let(:clock) { Time.at(1620000000000 / 1000) }

  let(:descr) { DefaultContextDataDeserializer.new }
  let(:json) { resource("context.json") }
  let(:data) { descr.deserialize(json, 0, json.length) }

  let(:publish_future) { OpenStruct.new(success?: true) }
  let(:event_handler) do
    ev = instance_double(Absmartly::ContextPublisher)
    allow(ev).to receive(:publish).and_return(publish_future)
    ev
  end
  let(:event_logger) { nil }
  let(:variable_parser) { DefaultVariableParser.new }
  let(:audience_matcher) { AudienceMatcher.new(DefaultAudienceDeserializer.new) }
  let(:failure) { Exception.new("FAILED") }

  # A read still holding a snapshot a refresh has since replaced: resolved
  # against that snapshot under the assignment lock, as a read that captured
  # it before the refresh would be.
  def stale_read(context, name, state)
    context.instance_variable_get(:@assignment_mutex).synchronize do
      context.send(:cached_or_new_assignment, name, state)
    end
  end

  def slow_client_mock(delay: 0.1)
    client = instance_double(Client)
    allow(client).to receive(:context_data) do
      sleep(delay)
      OpenStruct.new(data_future: data, success?: true)
    end
    client
  end

  def fast_client_mock
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))
    client
  end

  def failed_client_mock
    client = instance_double(Client)
    allow(client).to receive(:context_data).and_return(
      OpenStruct.new(exception: failure, success?: false, data_future: nil)
    )
    client
  end

  describe "ABSmartly#create_context_async" do
    it "returns a context immediately before data is fetched" do
      config = ABSmartlyConfig.create
      config.client = slow_client_mock(delay: 0.5)
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)

      expect(context).to be_a(Context)
      expect(context.ready?).to be false
      expect(context.failed?).to be_falsey

      context.wait_until_ready
      expect(context.ready?).to be true
    end

    it "becomes ready once data is fetched" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      expect(context.ready?).to be true
      expect(context.failed?).to be_falsey
      expect(context.data).to eq(data)
    end

    it "can get treatment after becoming ready" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      treatment = context.treatment("exp_test_ab")
      expect(treatment).to be_a(Integer)
    end

    it "marks context as failed when fetch fails" do
      config = ABSmartlyConfig.create
      config.client = failed_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)
      context.wait_until_ready

      expect(context.failed?).to be true
    end

    it "fails the context instead of never becoming ready on an unparseable 200 body" do
      http_client = instance_double(HttpClient)
      allow(http_client).to receive(:get)
        .and_return(DefaultHttpClient.default_response(200, "OK", "application/json", "not json"))
      client_config = ClientConfig.create.tap do |c|
        c.endpoint = "https://localhost/v1"
        c.api_key = "k"
        c.application = "a"
        c.environment = "e"
      end
      config = ABSmartlyConfig.create
      config.client = Client.new(client_config, http_client)
      context_config = ContextConfig.create
      context_config.set_units(units)

      [ABSmartly.create(config).create_context(context_config),
       ABSmartly.create(config).create_context_async(context_config)].each do |context|
        context.wait_until_ready(5)
        expect([context.ready?, context.failed?]).to eq([true, true])
      end
    end

    it "raises for treatment before ready" do
      config = ABSmartlyConfig.create
      config.client = slow_client_mock(delay: 0.2)
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = sdk.create_context_async(context_config)

      expect { context.treatment("exp_test_ab") }
        .to raise_error(IllegalStateException, "ABSmartly Context is not yet ready")
      context.wait_until_ready
    end

    it "validates params just like create_context" do
      config = ABSmartlyConfig.create
      config.client = fast_client_mock
      sdk = ABSmartly.create(config)

      context_config = ContextConfig.create
      context_config.set_unit(:user_id, "")

      expect { sdk.create_context_async(context_config) }.to raise_error(ArgumentError)
    end
  end

  describe "Context.create_async" do
    let(:data_provider) { DefaultContextDataProvider.new(fast_client_mock) }

    it "creates an unready context" do
      context = Context.create_async(clock, ContextConfig.create, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      expect(context).to be_a(Context)
      expect(context.ready?).to be false
    end

    it "becomes ready after set_data with success" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      expect(context.ready?).to be false

      context.set_data(OpenStruct.new(data_future: data, success?: true))

      expect(context.ready?).to be true
      expect(context.data).to eq(data)
    end

    it "becomes failed after set_data with failure" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      expect(context.failed?).to be true
    end

    it "keeps data a refresh installed when the initial fetch then fails" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      context.refresh
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      expect(context.ready?).to be true
      expect(context.failed?).to be_falsey
      expect(context.experiments).to eq(data.experiments.map(&:name))
    end

    it "keeps newer data a refresh installed when the initial fetch then succeeds late" do
      events = []
      logger = Class.new(ContextEventLogger) do
        define_method(:handle_event) { |event, data| events << [event, data] }
      end.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, logger, variable_parser, audience_matcher)
      context.refresh
      refreshed = context.data
      stale = descr.deserialize('{"experiments":[]}', 0, 18)
      context.set_data(OpenStruct.new(data_future: stale, success?: true))

      expect(context.data).to equal(refreshed)
      expect(events.last).to eq([ContextEventLogger::EVENT_TYPE::READY, refreshed])
    end

    it "logs only the error when the initial fetch fails on a context that is not ready" do
      events = []
      logger = Class.new(ContextEventLogger) do
        define_method(:handle_event) { |event, _data| events << event }
      end.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, logger, variable_parser, audience_matcher)
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      expect(events).to eq([ContextEventLogger::EVENT_TYPE::ERROR])
    end

    it "logs ready when a refresh made the context ready and the initial fetch then fails" do
      events = []
      logger = Class.new(ContextEventLogger) do
        define_method(:handle_event) { |event, _data| events << event }
      end.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, logger, variable_parser, audience_matcher)
      context.refresh
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      expect(events).to eq([ContextEventLogger::EVENT_TYPE::REFRESH, ContextEventLogger::EVENT_TYPE::ERROR,
                            ContextEventLogger::EVENT_TYPE::READY])
    end

    it "keeps an in-flight refresh usable when the initial fetch fails before it completes" do
      published = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        published.concat((event.goals || []).map(&:name))
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      provider = Object.new
      ready_data = data
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        expect(context.failed?).to be true
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end

      expect(context.failed?).to be false
      expect(context.ready_error).to be_nil
      context.track("goal1", nil)
      context.publish
      expect(published).to eq(["goal1"])
    end

    it "lets a variable parser call wait_until_ready while a refresh installs data" do
      calls = []
      holder = {}
      parser = Object.new
      parser.define_singleton_method(:parse) do |context, _experiment, _variant, config|
        calls << context.wait_until_ready(0).equal?(holder[:context]) if holder[:context]
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create(clock, context_config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, parser, audience_matcher)
      holder[:context] = context
      allow(data_provider).to receive(:context_data).and_return(OpenStruct.new(data_future: data, success?: true))

      expect { context.refresh }.not_to raise_error
      expect(calls).not_to be_empty
      expect(calls).to all(be true)
    end

    it "lets a variable parser call wait_until_ready while the initial async data is installed" do
      holder = {}
      calls = []
      parser = Object.new
      parser.define_singleton_method(:parse) do |context, _experiment, _variant, config|
        calls << [context.wait_until_ready(0).equal?(holder[:context]),
                  context.wait_until_ready.equal?(holder[:context])]
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, parser, audience_matcher)
      holder[:context] = context

      expect { Timeout.timeout(5) { context.set_data(OpenStruct.new(data_future: data, success?: true)) } }
        .not_to raise_error
      expect(calls).not_to be_empty
      expect(calls.flatten).to all(be true)
      expect(context.ready?).to be true
    end

    it "lets a variable parser call wait_until_ready from a fiber while the initial async data is installed" do
      holder = {}
      calls = []
      parser = Object.new
      parser.define_singleton_method(:parse) do |context, _experiment, _variant, config|
        calls << Fiber.new { context.wait_until_ready.equal?(holder[:context]) }.resume
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, parser, audience_matcher)
      holder[:context] = context

      expect { Timeout.timeout(5) { context.set_data(OpenStruct.new(data_future: data, success?: true)) } }
        .not_to raise_error
      expect(calls).not_to be_empty
      expect(calls).to all(be true)
      expect(context.ready?).to be true
      expect(context.instance_variable_get(:@building_threads)).to be_empty
    end

    it "does not hold the readiness lock while the variable parser runs" do
      in_parser = Queue.new
      release = Queue.new
      parser = Object.new
      parser.define_singleton_method(:parse) do |_context, _experiment, _variant, config|
        unless Thread.current[:parsed]
          Thread.current[:parsed] = true
          in_parser << true
          release.pop
        end
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, parser, audience_matcher)
      installer = Thread.new { context.set_data(OpenStruct.new(data_future: data, success?: true)) }
      begin
        Timeout.timeout(5) { in_parser.pop }
        expect(Timeout.timeout(1) { context.wait_until_ready(0) }).to equal(context)
        expect(context.ready?).to be false
      ensure
        release << true
        installer.join(5) || installer.kill
      end
      expect(context.ready?).to be true
    end

    it "a publish that saw the context failed keeps goals tracked after a refresh recovered it" do
      published = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        published.concat((event.goals || []).map(&:name))
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release_refresh = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release_refresh.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)

      # A refresh is in flight when the initial fetch fails. A publish then
      # sees the context failed and pauses before it drops the queue; the
      # refresh recovers and a new goal is tracked before the publish resumes.
      seen_failed = Queue.new
      resume = Queue.new
      ready_mutex = context.instance_variable_get(:@ready_mutex)
      allow(ready_mutex).to receive(:synchronize).and_wrap_original do |original, &block|
        if Thread.current[:role] == :publisher && !Thread.current[:paused]
          Thread.current[:paused] = true
          seen_failed << true
          resume.pop
        end
        original.call(&block)
      end
      refresher = Thread.new { context.refresh }
      publisher = nil
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.track("while_failed", nil)
        publisher = Thread.new do
          Thread.current[:role] = :publisher
          context.publish
        end
        Timeout.timeout(5) { seen_failed.pop }
        release_refresh << true
        Timeout.timeout(5) { refresher.join }
        expect(context.failed?).to be false
        context.track("after_recovery", nil)
        resume << true
        Timeout.timeout(5) { publisher.join }
      ensure
        release_refresh << true
        resume << true
        [refresher, publisher].compact.each { |t| t.join(5) || t.kill }
      end

      context.publish
      expect(published).to include("after_recovery")
      expect(context.pending_count).to eq(0)
    end

    it "does not parse a late initial payload a refresh already superseded, and logs it as ready" do
      parses = 0
      parser = Object.new
      parser.define_singleton_method(:parse) do |_context, _experiment, _variant, config|
        parses += 1
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      events = []
      logger = Class.new(ContextEventLogger) do
        define_method(:handle_event) { |event, _data| events << event }
      end.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, logger, parser, audience_matcher)
      context.refresh
      after_refresh = parses
      context.set_data(OpenStruct.new(data_future: data, success?: true))

      expect(parses).to eq(after_refresh)
      expect(events).to eq([ContextEventLogger::EVENT_TYPE::REFRESH, ContextEventLogger::EVENT_TYPE::READY])
    end

    it "keeps refreshed data after an initial payload has already started parsing" do
      parsing = Queue.new
      release = Queue.new
      parser = Object.new
      parser.define_singleton_method(:parse) do |_c, _e, _v, config|
        if Thread.current[:initial_build] && !Thread.current[:paused]
          Thread.current[:paused] = true
          parsing << true
          release.pop
        end
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      provider = Object.new
      refreshed = DefaultContextDataDeserializer.new.deserialize(
        '{"experiments":[]}', 0, 18
      )
      provider.define_singleton_method(:context_data) do
        OpenStruct.new(data_future: refreshed, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     event_handler, event_logger, parser, audience_matcher)
      installer = Thread.new do
        Thread.current[:initial_build] = true
        context.set_data(OpenStruct.new(data_future: data, success?: true))
      end
      begin
        Timeout.timeout(5) { parsing.pop }
        context.refresh
        release << true
        Timeout.timeout(5) { installer.join }
      ensure
        release << true
        installer.join(5) || installer.kill
      end
      expect(context.data).to equal(refreshed)
    end

    def blocking_parser(in_parser, release, raise_first: false)
      parser = Object.new
      parser.define_singleton_method(:parse) do |_context, _experiment, _variant, config|
        if Thread.current[:block_parse] && !Thread.current[:parsed]
          Thread.current[:parsed] = true
          in_parser << true
          release.pop
          raise "parser failed" if raise_first
        end
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      parser
    end

    it "keeps another thread's wait blocked while the initial data is still being built" do
      in_parser = Queue.new
      release = Queue.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider, event_handler, event_logger,
                                     blocking_parser(in_parser, release), audience_matcher)
      installer = Thread.new do
        Thread.current[:block_parse] = true
        context.set_data(OpenStruct.new(data_future: data, success?: true))
      end
      waiter = nil
      begin
        Timeout.timeout(5) { in_parser.pop }
        waiter = Thread.new do
          context.wait_until_ready
          context.ready?
        end
        Timeout.timeout(5) { sleep 0.01 until waiter.status == "sleep" }
        expect(waiter.alive?).to be true
        release << true
        expect(Timeout.timeout(5) { waiter.value }).to be true
      ensure
        release << true
        [installer, waiter].compact.each { |t| t.join(5) || t.kill }
      end
    end

    it "lets a thread whose own build raised wait normally afterwards" do
      in_parser = Queue.new
      release = Queue.new
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider, event_handler, event_logger,
                                     blocking_parser(in_parser, release, raise_first: true), audience_matcher)
      release << true
      builder = Thread.new do
        Thread.current[:block_parse] = true
        begin
          context.refresh
        rescue RuntimeError => e
          e
        end
        # This thread no longer builds anything: its wait must block until
        # another thread installs the data, not return at once.
        context.wait_until_ready
        context.ready?
      end
      begin
        Timeout.timeout(5) { in_parser.pop }
        Timeout.timeout(5) { sleep 0.01 until builder.status == "sleep" }
        expect(context.ready?).to be false
        context.set_data(OpenStruct.new(data_future: data, success?: true))
        expect(Timeout.timeout(5) { builder.value }).to be true
      ensure
        builder.join(5) || builder.kill
      end
    end

    it "a concurrent failing refresh does not clear the initial builder's self-wait guard" do
      a_in = Queue.new
      b_done = Queue.new
      waited = Queue.new
      holder = {}
      parser = Object.new
      parser.define_singleton_method(:parse) do |_context, _experiment, _variant, config|
        case Thread.current[:role]
        when :a
          unless Thread.current[:once]
            Thread.current[:once] = true
            a_in << true
            b_done.pop
            holder[:context].wait_until_ready
            waited << true
          end
        when :b
          raise "boom"
        end
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) { OpenStruct.new(data_future: ready_data, success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, event_handler, event_logger,
                                     parser, audience_matcher)
      holder[:context] = context
      a = Thread.new do
        Thread.current[:role] = :a
        context.set_data(provider.context_data)
      end
      b = nil
      begin
        Timeout.timeout(5) { a_in.pop }
        b = Thread.new do
          Thread.current[:role] = :b
          begin
            context.refresh
          rescue RuntimeError
            nil
          end
        end
        Timeout.timeout(5) { b.join }
        b_done << true
        expect(Timeout.timeout(5) { waited.pop }).to be true
        Timeout.timeout(5) { a.join }
        expect(context.ready?).to be true
      ensure
        b_done << true
        [a, b].compact.each { |t| t.join(5) || t.kill }
      end
    end

    it "a nested build on the same thread keeps the outer builder's membership" do
      holder = {}
      results = []
      parser = Object.new
      parser.define_singleton_method(:parse) do |_context, _experiment, _variant, config|
        if holder[:context] && !Thread.current[:nested]
          Thread.current[:nested] = true
          holder[:context].refresh
          results << holder[:context].wait_until_ready.equal?(holder[:context])
        end
        JSON.parse(config, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) { OpenStruct.new(data_future: ready_data, success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, event_handler, event_logger,
                                     parser, audience_matcher)
      holder[:context] = context
      Timeout.timeout(5) { context.set_data(provider.context_data) }

      expect(results).to eq([true])
      expect(context.ready?).to be true
      expect(context.instance_variable_get(:@building_threads)).to be_empty
    end

    it "an in-flight publish removes only its own batch after a failed-context clear and recovery" do
      publish_in = Queue.new
      publish_out = Queue.new
      refresh_in = Queue.new
      refresh_out = Queue.new
      sent = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        names = (event.goals || []).map(&:name)
        sent << names
        if names.include?("before_failure")
          publish_in << true
          publish_out.pop
        end
        OpenStruct.new(success?: true)
      end
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        refresh_in << true
        refresh_out.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, handler, event_logger,
                                     variable_parser, audience_matcher)
      context.track("before_failure", nil)
      a = Thread.new { context.publish }
      b = nil
      begin
        Timeout.timeout(5) { publish_in.pop }
        b = Thread.new { context.refresh }
        Timeout.timeout(5) { refresh_in.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.publish
        refresh_out << true
        Timeout.timeout(5) { b.join }
        context.track("after_recovery", nil)
        publish_out << true
        Timeout.timeout(5) { a.join }

        expect(context.pending_count).to eq(1)
        context.publish
        expect(sent).to eq([["before_failure"], ["after_recovery"]])
        expect(context.pending_count).to eq(0)
      ensure
        refresh_out << true
        publish_out << true
        [a, b].compact.each { |t| t.join(5) || t.kill }
      end
    end

    it "a goal tracked after recovery is never dropped by a failed-context clear" do
      sent = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        sent.concat((event.goals || []).map(&:name))
        OpenStruct.new(success?: true)
      end
      refresh_in = Queue.new
      refresh_out = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        refresh_in << true
        refresh_out.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, handler, event_logger,
                                     variable_parser, audience_matcher)
      # Pause the publisher at its queue-lock call inside the failed path: the
      # clear must happen under the readiness lock, so a recovering refresh
      # either finishes first (no clear) or waits for the clear to finish.
      at_clear = Queue.new
      resume = Queue.new
      queue_mutex = context.instance_variable_get(:@queue_mutex)
      allow(queue_mutex).to receive(:synchronize).and_wrap_original do |original, &block|
        if Thread.current[:role] == :publisher && !Thread.current[:paused]
          Thread.current[:paused] = true
          at_clear << true
          resume.pop
        end
        original.call(&block)
      end
      refresher = Thread.new { context.refresh }
      publisher = nil
      begin
        Timeout.timeout(5) { refresh_in.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        publisher = Thread.new do
          Thread.current[:role] = :publisher
          context.publish
        end
        Timeout.timeout(5) { at_clear.pop }
        refresh_out << true
        expect(refresher.join(0.5)).to be_nil
        expect(context.failed?).to be true
        context.track("probe", nil)
        resume << true
        Timeout.timeout(5) { publisher.join }
        Timeout.timeout(5) { refresher.join }
        expect(context.failed?).to be false
        context.track("after", nil)
        context.publish
        expect(sent).to include("after")
      ensure
        refresh_out << true
        resume << true
        [refresher, publisher].compact.each { |t| t.join(5) || t.kill }
      end
    end

    it "finalize does not raise the initial-fetch error when a refresh recovers during its flush" do
      refresh_in = Queue.new
      refresh_out = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        refresh_in << true
        refresh_out.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      handler = Object.new
      handler.define_singleton_method(:publish) { |_context, _event| OpenStruct.new(success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, handler, event_logger,
                                     variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      Timeout.timeout(5) { refresh_in.pop }
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))

      # The refresh recovers right after finalize's flush returned the load error.
      original = context.method(:flush)
      allow(context).to receive(:flush) do |**kwargs|
        result = original.call(**kwargs)
        if kwargs[:sealing] && !refresher.status.nil? && refresher.alive?
          refresh_out << true
          Timeout.timeout(5) { refresher.join }
        end
        result
      end
      begin
        expect { Timeout.timeout(5) { context.finalize } }.not_to raise_error
      ensure
        refresh_out << true
        refresher.join(5) || refresher.kill
      end
      expect(context.failed?).to be false
    end

    it "resolves assignments made while failed against the recovered data" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.set_override("exp_test_ab", 1)
        expect(context.peek_treatment("exp_test_ab")).to eq(1)
        # A second assignment built while failed: marking one must not
        # unmark another.
        expect(context.peek_treatment("exp_test_abc")).to eq(0)
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end

      expect(context.failed?).to be false
      expect(context.variable_value("banner.size", "default")).to eq("large")
      expect(context.variable_value("button.color", "default")).not_to eq("default")
      context.publish
      expect(exposures.map(&:first)).to eq(%w[exp_test_ab exp_test_abc])
      expect(exposures.first).to eq(["exp_test_ab", 1, 1])
      expect(exposures.last[1]).to eq(2)
    end

    it "does not keep an assignment a read built from the failed snapshot after recovery" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        failed_state = context.instance_variable_get(:@state)
        context.set_override("exp_test_ab", 1)
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      # A reader that captured the failed snapshot before the refresh committed
      # finishes only after the recovery installed the recovered data.
      cache = context.instance_variable_get(:@assignment_cache)
      expect(cache).to be_empty
      stale_read(context, "exp_test_ab", failed_state)
      expect(cache).to be_empty

      expect(context.variable_value("banner.size", "default")).to eq("large")
      context.publish
      expect(exposures).to eq([["exp_test_ab", 1, 1]])
    end

    it "keeps one exposure for a read that raced an ordinary refresh" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) { OpenStruct.new(data_future: ready_data, success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create(clock, context_config, OpenStruct.new(data_future: data, success?: true), provider,
                               handler, event_logger, variable_parser, audience_matcher)
      old_state = context.instance_variable_get(:@state)
      context.refresh
      %w[exp_test_ab not_found].each do |name|
        context.send(:queue_exposure, stale_read(context, name, old_state))
        context.treatment(name)
      end
      context.publish

      expect(exposures.map(&:first)).to eq(%w[exp_test_ab not_found])
      expect(exposures.last).to eq(["not_found", 0, 0])
    end

    it "reuses an assignment while the context stays failed" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
      context.set_override("exp_test_ab", 1)
      context.treatment("exp_test_ab")
      context.treatment("exp_test_ab")

      expect(context.pending_count).to eq(1)
    end

    describe "a read still on the failed snapshot after a refresh recovered the context" do
      let(:exposures) { [] }

      def recovered_context
        sent = exposures
        handler = Object.new
        handler.define_singleton_method(:publish) do |_context, event|
          sent.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
          OpenStruct.new(success?: true)
        end
        in_refresh = Queue.new
        release = Queue.new
        ready_data = data
        provider = Object.new
        provider.define_singleton_method(:context_data) do
          in_refresh << true
          release.pop
          OpenStruct.new(data_future: ready_data, success?: true)
        end
        context_config = ContextConfig.create
        context_config.set_units(units)
        context = Context.create_async(clock, context_config, provider,
                                       handler, event_logger, variable_parser, audience_matcher)
        refresher = Thread.new { context.refresh }
        begin
          Timeout.timeout(5) { in_refresh.pop }
          context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
          failed_state = context.instance_variable_get(:@state)
          yield context if block_given?
          release << true
          Timeout.timeout(5) { refresher.join }
        ensure
          release << true
          refresher.join(5) || refresher.kill
        end
        [context, failed_state]
      end

      it "does not cause a second exposure of a recovered assignment" do
        context, failed_state = recovered_context
        context.treatment("exp_test_ab")
        stale_read(context, "exp_test_ab", failed_state)
        context.treatment("exp_test_ab")
        context.publish

        expect(exposures.size).to eq(1)
        expect(exposures.first[0..1]).to eq(["exp_test_ab", 1])
      end

      it "keeps it when the recovered data lacks the experiment too" do
        context, failed_state = recovered_context
        context.send(:queue_exposure, stale_read(context, "not_found", failed_state))
        context.treatment("not_found")
        context.publish

        expect(exposures).to eq([["not_found", 0, 0]])
      end

      it "keeps a forced one when the recovered data lacks the experiment too" do
        context, failed_state = recovered_context { |ctx| ctx.set_override("not_found", 2) }
        context.send(:queue_exposure, stale_read(context, "not_found", failed_state))
        expect(context.treatment("not_found")).to eq(2)
        context.publish

        expect(exposures).to eq([["not_found", 0, 2]])
      end

      it "reuses the assignment exposed while failed" do
        context, failed_state = recovered_context { |ctx| ctx.treatment("exp_test_ab") }
        context.send(:queue_exposure, stale_read(context, "exp_test_ab", failed_state))
        context.publish

        expect(exposures).to eq([["exp_test_ab", 0, 0]])
      end
    end

    it "does not mark or check assignments on cached reads of a context that never failed" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create(clock, context_config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      context.peek_treatment("exp_test_ab")
      assignment = context.instance_variable_get(:@assignment_cache)["exp_test_ab"]
      expect(assignment.instance_variable_get(:@failed_snapshot)).to be false
      expect(assignment).not_to receive(:instance_variable_get)
      3.times { context.peek_treatment("exp_test_ab") }
    end

    it "keeps a failed-snapshot assignment ineligible for reuse when its rebuild raises" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.set_override("exp_test_ab", 1)
        context.peek_treatment("exp_test_ab")
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      context.instance_variable_get(:@overrides).delete(:exp_test_ab)
      allow(VariantAssigner).to receive(:new).and_raise(RuntimeError, "matcher failed")
      expect { context.treatment("exp_test_ab") }.to raise_error(RuntimeError, "matcher failed")
      allow(VariantAssigner).to receive(:new).and_call_original
      context.set_override("exp_test_ab", 1)

      expect(context.variable_value("banner.size", "default")).to eq("large")
      context.publish
      expect(exposures).to eq([["exp_test_ab", 1, 1]])
    end

    it "does not expose again an experiment the recovered data still lacks" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.treatment("not_found")
        context.treatment("exp_test_ab")
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      context.treatment("not_found")
      context.treatment("exp_test_ab")
      context.publish

      expect(exposures).to eq([["not_found", 0, 0], ["exp_test_ab", 0, 0], ["exp_test_ab", 1, 1]])
    end

    it "honors a cleared override after recovery still lacks the experiment" do
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.set_override("not_found", 1)
        expect(context.treatment("not_found")).to eq(1)
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      context.set_override("not_found", nil)

      expect(context.treatment("not_found")).to eq(0)
    end

    it "resolves an assignment made while failed once a later refresh supplies the experiment" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      payloads = [ContextData.new, data]
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: payloads.shift, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.set_override("exp_test_ab", 1)
        expect(context.treatment("exp_test_ab")).to eq(1)
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      expect(context.failed?).to be false
      expect(context.variable_value("banner.size", "default")).to eq("default")

      release << true
      expect { context.refresh }.not_to raise_error
      expect(context.treatment("exp_test_ab")).to eq(1)
      values = Array.new(3) { context.variable_value("banner.size", "default") }
      expect(context.treatment("exp_test_ab")).to eq(1)
      context.publish

      # Owner decision: after the later refresh either outcome is accepted.
      # Resolved again: one new exposure with the real experiment id, and the
      # recovered variant's variables. Kept (as java-sdk and javascript-sdk
      # keep the cached id-0 assignment): no new exposure, and the default.
      # The override's variant is served either way, reads stay stable, and
      # nothing is exposed twice.
      expect(exposures.first).to eq(["exp_test_ab", 0, 1])
      expect(values.uniq.size).to eq(1)
      expect([exposures.drop(1), values.first])
        .to eq([[["exp_test_ab", 1, 1]], "large"]).or eq([[], "default"])
    end

    it "keeps a failed assignment ineligible when an interrupt lands while its replacement is cached" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map { |e| [e.name, e.id, e.variant] })
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.set_override("exp_test_ab", 1)
        context.treatment("exp_test_ab")
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      untagging = Queue.new
      resume = Queue.new
      cache = context.instance_variable_get(:@assignment_cache)
      old_assignment = cache["exp_test_ab"]
      cache.define_singleton_method(:[]=) do |key, value|
        result = super(key, value)
        if Thread.current[:gate]
          Thread.current[:gate] = false
          untagging << true
          resume.pop
        end
        result
      end
      reader = Thread.new do
        Thread.current[:gate] = true
        context.variable_value("banner.size", "default")
      rescue Interrupt
        nil
      end
      Timeout.timeout(5) { untagging.pop }
      reader.raise(Interrupt)
      resume << true
      Timeout.timeout(5) { reader.join }

      expect(old_assignment.instance_variable_get(:@failed_snapshot)).to be true
      # The recovered assignment is cached and reused: repeated reads add no exposure.
      3.times { expect(context.variable_value("banner.size", "default")).to eq("large") }
      context.publish
      expect(exposures).to eq([["exp_test_ab", 0, 1], ["exp_test_ab", 1, 1]])
    end

    it "never caches an unmarked failed assignment when an interrupt lands while a failed read is cached" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
      tagging = Queue.new
      resume = Queue.new
      cache = context.instance_variable_get(:@assignment_cache)
      cache.define_singleton_method(:[]=) do |key, value|
        result = super(key, value)
        if Thread.current[:gate]
          Thread.current[:gate] = false
          tagging << true
          resume.pop
        end
        result
      end
      reader = Thread.new do
        Thread.current[:gate] = true
        context.peek_treatment("exp_test_ab")
      rescue Interrupt
        nil
      end
      Timeout.timeout(5) { tagging.pop }
      reader.raise(Interrupt)
      resume << true
      Timeout.timeout(5) { reader.join }

      cache = context.instance_variable_get(:@assignment_cache)
      expect(cache.values).not_to be_empty
      expect(cache.values).to all(satisfy { |cached| cached.instance_variable_get(:@failed_snapshot) })
    end

    # Each gate parks refresh on a line and interrupts it there: just after the
    # snapshot install inside the mask, and the first line after the mask.
    {
      "inside the recovery commit" => ["@state = state", 2, "@failed = false"],
      "right after the recovery commit" => ["@ready_condvar.broadcast", 4,
                                            "log_event(ContextEventLogger::EVENT_TYPE::REFRESH, data_future.data_future)"]
    }.each do |where, (anchor, offset, gated)|
      it "completes recovery when an interrupt lands #{where}" do
        sent = []
        handler = Object.new
        handler.define_singleton_method(:publish) do |_context, event|
          sent.concat((event.goals || []).map(&:name))
          OpenStruct.new(success?: true)
        end
        in_refresh = Queue.new
        release = Queue.new
        ready_data = data
        calls = 0
        provider = Object.new
        provider.define_singleton_method(:context_data) do
          calls += 1
          if calls == 1
            in_refresh << true
            release.pop
          end
          OpenStruct.new(data_future: ready_data, success?: true)
        end
        context_config = ContextConfig.create
        context_config.set_units(units)
        context = Context.create_async(clock, context_config, provider,
                                       handler, event_logger, variable_parser, audience_matcher)
        source, start = Context.instance_method(:refresh).source_location
        lines = File.readlines(source)
        commit_line = lines.each_with_index.find { |line, index| index >= start && line.strip == anchor }.last + offset
        expect(lines[commit_line - 1].strip).to eq(gated)
        committing = Queue.new
        resume_commit = Queue.new
        trace = TracePoint.new(:line) do |event|
          if event.path == source && event.lineno == commit_line && Thread.current[:gate]
            Thread.current[:gate] = false
            committing << true
            resume_commit.pop
          end
        end
        trace.enable
        refresher = Thread.new do
          Thread.current[:gate] = true
          context.refresh
        rescue Interrupt
          nil
        end
        begin
          Timeout.timeout(5) { in_refresh.pop }
          context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
          release << true
          Timeout.timeout(5) { committing.pop }
          refresher.raise(Interrupt)
          resume_commit << true
          Timeout.timeout(5) { refresher.join }
        ensure
          trace.disable
          resume_commit << true
          release << true
          refresher.join(5) || refresher.kill
        end

        expect(context.failed?).to be false
        expect(context.ready_error).to be_nil
        expect(context.data).to equal(data)
        context.track("after_recovery", nil)
        context.publish
        expect(sent).to eq(["after_recovery"])
        context.refresh
        expect(calls).to eq(2)
      end
    end

    it "does not mask an unrelated cache write while a failed-snapshot assignment remains" do
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.peek_treatment("not_found")
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      expect(context.failed?).to be false
      cached = context.instance_variable_get(:@assignment_cache)["not_found"]
      expect(cached.instance_variable_get(:@failed_snapshot)).to be true

      masks = 0
      allow(Thread).to receive(:handle_interrupt).and_wrap_original do |original, *args, &block|
        masks += 1
        original.call(*args, &block)
      end
      context.peek_treatment("exp_test_ab")
      expect(masks).to eq(0)
      context.set_override("exp_test_ab", 2)
      context.peek_treatment("exp_test_ab")
      expect(masks).to eq(0)
    end

    # The second operation waits behind a publish the collector rejects; the
    # initial fetch fails and a goal is tracked before it takes its turn.
    [
      ["a publish waiting for an in-flight one does not send events after the initial fetch failed",
       :publish, ->(result, failure, context) {
         expect(result).to equal(failure)
         expect(context.failed?).to be true
       }],
      ["a finalize waiting for an in-flight publish seals without sending events after the initial fetch failed",
       :finalize, ->(result, _failure, context) {
         expect(result).to be_nil
         expect(context.finalized?).to be true
       }]
    ].each do |label, operation, outcome|
      it label do
        sent = []
        in_publish = Queue.new
        release = Queue.new
        handler = Object.new
        handler.define_singleton_method(:publish) do |_context, event|
          sent << (event.goals || []).map(&:name)
          if sent.size == 1
            in_publish << true
            release.pop
            next OpenStruct.new(success?: false, status: 503)
          end
          OpenStruct.new(success?: true)
        end
        context_config = ContextConfig.create
        context_config.set_units(units)
        context = Context.create_async(clock, context_config, data_provider,
                                       handler, event_logger, variable_parser, audience_matcher)
        context.track("before_failure", nil)
        first = Thread.new { context.publish }
        second = nil
        result = nil
        begin
          Timeout.timeout(5) { in_publish.pop }
          second = Thread.new { context.public_send(operation) }
          Timeout.timeout(5) { Thread.pass until second.status == "sleep" }
          context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
          context.track("after_failure", nil)
          release << true
          Timeout.timeout(5) { first.join }
          result = Timeout.timeout(5) { second.value }
        ensure
          release << true
          first.join(5) || first.kill
          second&.join(5) || second&.kill
        end

        instance_exec(result, failure, context, &outcome)
        expect(sent).to eq([["before_failure"]])
        expect(context.pending_count).to eq(0)
      end
    end

    it "does not send exposures a publish dropped while failed once a refresh recovers" do
      exposures = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        exposures.concat((event.exposures || []).map(&:name))
        OpenStruct.new(success?: true)
      end
      in_refresh = Queue.new
      release = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        in_refresh << true
        release.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider,
                                     handler, event_logger, variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      begin
        Timeout.timeout(5) { in_refresh.pop }
        context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
        context.treatment("while_failed_exp")
        expect(context.publish).to equal(failure)
        release << true
        Timeout.timeout(5) { refresher.join }
      ensure
        release << true
        refresher.join(5) || refresher.kill
      end
      context.treatment("exp_test_ab")
      context.publish

      expect(exposures).to eq(["exp_test_ab"])
    end

    %i[publish finalize].each do |operation|
      it "keeps failure installation outside #{operation}'s batch-selection boundary" do
        sent = []
        handler = Object.new
        handler.define_singleton_method(:publish) do |_context, event|
          sent.concat((event.goals || []).map(&:name))
          sent.concat((event.exposures || []).map(&:name))
          OpenStruct.new(success?: true)
        end
        config = ContextConfig.create
        config.set_units(units)
        context = Context.create_async(clock, config, data_provider,
                                       handler, event_logger, variable_parser, audience_matcher)
        context.track("before_failure", nil)
        early = Assignment.new
        early.name = "before_failure_exp"
        context.queue_exposure(early)
        # Each copy is part of the failure/selection transaction, including a
        # copy moved earlier than the scheduling gate below.
        %i[@achievements @exposures].each do |name|
          array = context.instance_variable_get(name)
          allow(array).to receive(:dup).and_wrap_original do |original|
            expect(context.instance_variable_get(:@ready_mutex).owned?).to be true
            original.call
          end
        end
        # Park the publisher the moment it releases the readiness lock that
        # covers its failure check and batch selection, then fail the fetch and
        # queue a late goal and exposure; the dup spies above pin the copies.
        ready_mutex = context.instance_variable_get(:@ready_mutex)
        publish_mutex = context.instance_variable_get(:@publish_mutex)
        queue_mutex = context.instance_variable_get(:@queue_mutex)
        parked = Queue.new
        resume = Queue.new
        released = false
        allow(ready_mutex).to receive(:synchronize).and_wrap_original do |original, &block|
          result = original.call(&block)
          if Thread.current[:gate_selection] && publish_mutex.owned?
            Thread.current[:gate_selection] = false
            released = true
            parked << true
            resume.pop
          end
          result
        end
        # A copy taken under the queue lock alone, before that readiness lock
        # is taken, would also be outside the boundary: park there too.
        allow(queue_mutex).to receive(:synchronize).and_wrap_original do |original, &block|
          if Thread.current[:gate_selection] && publish_mutex.owned? && !ready_mutex.owned? && !released
            Thread.current[:gate_selection] = false
            parked << true
            resume.pop
          end
          original.call(&block)
        end
        publisher = Thread.new do
          Thread.current[:gate_selection] = true
          context.public_send(operation)
        end
        begin
          Timeout.timeout(5) { parked.pop }
          context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
          context.track("after_failure", nil)
          late = Assignment.new
          late.name = "after_failure_exp"
          context.queue_exposure(late)
          resume << true
          Timeout.timeout(5) { publisher.join }
        ensure
          resume << true
          publisher.join(1) || publisher.kill
        end
        expect(sent).to eq(["before_failure", "before_failure_exp"])
      end
    end

    it "lets a supplied exposure clock wait for readiness during concurrent batch selection" do
      entered = Queue.new
      resume = Queue.new
      custom_clock = Object.new
      custom_clock.define_singleton_method(:to_i) do
        if Thread.current[:clock_gate]
          Thread.current[:clock_gate] = false
          entered << true
          resume.pop
          context.wait_until_ready(0)
        end
        123
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      custom_clock.define_singleton_method(:context) { context }
      exposure = Thread.new do
        Thread.current[:clock_gate] = true
        context.treatment("exp_test_ab")
      end
      publisher = nil
      begin
        Timeout.timeout(5) { entered.pop }
        context.track("goal", nil)
        publisher = Thread.new { context.publish }
        # Publish must complete without waiting for the clock callback.
        Timeout.timeout(2) { publisher.value }
        resume << true
        Timeout.timeout(2) { exposure.value }
      ensure
        resume << true
        exposure.join(2) || exposure.kill
        publisher&.join(2) || publisher&.kill
      end
    end

    it "calls the supplied exposure clock only for a new exposure" do
      calls = 0
      custom_clock = Object.new
      custom_clock.define_singleton_method(:to_i) { calls += 1; 123 }
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      3.times { context.treatment("exp_test_ab") }
      expect(calls).to eq(1)
    end

    it "calls an exposure clock once across concurrent reads and allows clock reentry" do
      entered = Queue.new
      resume = Queue.new
      calls = 0
      custom_clock = Object.new
      context = nil
      custom_clock.define_singleton_method(:to_i) do
        calls += 1
        context.treatment("exp_test_ab")
        entered << true
        resume.pop
        123
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      first = Thread.new { context.treatment("exp_test_ab") }
      second = nil
      begin
        Timeout.timeout(5) { entered.pop }
        second = Thread.new { context.treatment("exp_test_ab") }
        expect(second.join(0.1)).to be_nil
        resume << true
        Timeout.timeout(5) { first.value; second.value }
      ensure
        resume << true
        first.join(2) || first.kill
        second&.join(2) || second&.kill
      end
      expect(calls).to eq(1)
      expect(context.pending_count).to eq(1)
    end

    it "can retry exposure after the supplied clock raises" do
      calls = 0
      custom_clock = Object.new
      custom_clock.define_singleton_method(:to_i) do
        calls += 1
        raise "clock failed" if calls == 1

        123
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      expect { context.treatment("exp_test_ab") }.to raise_error("clock failed")
      expect(context.pending_count).to eq(0)
      context.treatment("exp_test_ab")
      expect(context.pending_count).to eq(1)
    end

    it "allows a clock to wait for a distinct concurrent treatment and preserves both exposures" do
      custom_clock = Object.new
      context = nil
      custom_clock.define_singleton_method(:to_i) do
        if Thread.current[:outer_clock]
          Thread.current[:outer_clock] = false
          Timeout.timeout(2) { Thread.new { context.treatment("exp_test_abc") }.value }
        end
        123
      end
      names = []
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, event|
        names.concat((event.exposures || []).map(&:name))
        OpenStruct.new(success?: true)
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, handler, event_logger, variable_parser, audience_matcher)
      begin
        Thread.current[:outer_clock] = true
        context.treatment("exp_test_ab")
      ensure
        Thread.current[:outer_clock] = nil
      end
      expect(context.pending_count).to eq(2)
      context.publish
      expect(names).to eq(%w[exp_test_abc exp_test_ab])
    end

    it "does not enqueue an exposure after close seals during its clock callback" do
      custom_clock = Object.new
      context = nil
      custom_clock.define_singleton_method(:to_i) { context.close; 123 }
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      expect { context.treatment("exp_test_ab") }.to raise_error(IllegalStateException)
      expect(context.pending_count).to eq(0)
      expect(context.instance_variable_get(:@exposing)).to be_empty
    end

    it "lets a competing exposure retry when the first clock fails" do
      entered = Queue.new
      resume = Queue.new
      calls = 0
      custom_clock = Object.new
      custom_clock.define_singleton_method(:to_i) do
        calls += 1
        if calls == 1
          entered << true
          resume.pop
          raise "clock failed"
        end
        123
      end
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      first = Thread.new { context.treatment("exp_test_ab") rescue nil }
      second = nil
      begin
        Timeout.timeout(5) { entered.pop }
        second = Thread.new { context.treatment("exp_test_ab") }
        expect(second.join(0.1)).to be_nil
        resume << true
        Timeout.timeout(5) { first.value; second.value }
      ensure
        resume << true
        first.join(2) || first.kill
        second&.join(2) || second&.kill
      end
      expect(context.pending_count).to eq(1)
      expect(calls).to eq(2)
    end

    it "lets an exposure waiter time out while the owning clock is blocked" do
      entered = Queue.new
      resume = Queue.new
      custom_clock = Object.new
      custom_clock.define_singleton_method(:to_i) { entered << true; resume.pop; 123 }
      config = ContextConfig.create
      config.set_units(units)
      context = Context.create(custom_clock, config, OpenStruct.new(data_future: data, success?: true),
                               data_provider, event_handler, event_logger, variable_parser, audience_matcher)
      owner = Thread.new { context.treatment("exp_test_ab") }
      begin
        Timeout.timeout(5) { entered.pop }
        expect { Timeout.timeout(0.1) { context.treatment("exp_test_ab") } }.to raise_error(Timeout::Error)
      ensure
        resume << true
        owner.join(2) || owner.kill
      end
      expect(context.pending_count).to eq(1)
    end

    it "keeps failed-snapshot provenance on the cached assignment only" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
      50.times do |i|
        context.set_override("exp_test_ab", i % 2)
        context.peek_treatment("exp_test_ab")
      end

      cache = context.instance_variable_get(:@assignment_cache)
      expect(cache.size).to eq(1)
      expect(cache.values.first.instance_variable_get(:@failed_snapshot)).to be true
      expect(context.instance_variable_defined?(:@failed_built)).to be false
    end

    it "lets a timeout interrupt a slow variable parser" do
      parser = DefaultVariableParser.new
      parser.define_singleton_method(:parse) do |context, experiment, variant, config|
        sleep 2
        super(context, experiment, variant, config)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider, event_handler, event_logger,
                                     parser, audience_matcher)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { Timeout.timeout(0.1) { context.set_data(OpenStruct.new(data_future: data, success?: true)) } }
        .to raise_error(Timeout::Error)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be < 1
      expect(context.instance_variable_get(:@building_threads)).to be_empty
    end

    it "keeps a caller's interrupt mask while a refresh parses variables" do
      parsing = Queue.new
      parser = DefaultVariableParser.new
      parser.define_singleton_method(:parse) do |context, experiment, variant, config|
        parsing << true if Thread.current[:signal_parse]
        sleep 0.05 if Thread.current[:signal_parse]
        super(context, experiment, variant, config)
      end
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) { OpenStruct.new(data_future: ready_data, success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create(clock, context_config, OpenStruct.new(data_future: data, success?: true), provider,
                               event_handler, event_logger, parser, audience_matcher)
      log = Queue.new
      worker = Thread.new do
        Thread.current[:signal_parse] = true
        Thread.handle_interrupt(Object => :never) do
          context.refresh
          log << :refresh_completed
        end
      rescue RuntimeError => e
        log << e.message
      end
      Timeout.timeout(5) { parsing.pop }
      worker.raise(RuntimeError, "async")
      Timeout.timeout(5) { worker.join }

      expect([log.pop, log.pop]).to eq([:refresh_completed, "async"])
      expect(context.instance_variable_get(:@building_threads)).to be_empty
    end

    it "keeps the timeout when it interrupts a refresh waiting to register as a builder" do
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) { OpenStruct.new(data_future: ready_data, success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create(clock, context_config, OpenStruct.new(data_future: data, success?: true), provider,
                               event_handler, event_logger, variable_parser, audience_matcher)
      ready_mutex = context.instance_variable_get(:@ready_mutex)
      held = Queue.new
      holder = Thread.new { ready_mutex.synchronize { held << true; sleep 0.6 } }
      Timeout.timeout(5) { held.pop }

      expect { Timeout.timeout(0.2) { context.refresh } }.to raise_error(Timeout::Error)
      Timeout.timeout(5) { holder.join }
      expect(context.instance_variable_get(:@building_threads)).to be_empty
    end

    it "does not leave a thread registered as a builder when a timeout lands during its cleanup" do
      holder = {}
      grabbed = Queue.new
      parser = DefaultVariableParser.new
      parser.define_singleton_method(:parse) do |context, experiment, variant, config|
        if Thread.current[:arm] && !Thread.current[:fired]
          Thread.current[:fired] = true
          mutex = holder[:context].instance_variable_get(:@ready_mutex)
          holder[:locker] = Thread.new { mutex.synchronize { grabbed << true; sleep 0.6 } }
          grabbed.pop
        end
        super(context, experiment, variant, config)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider, event_handler, event_logger,
                                     parser, audience_matcher)
      holder[:context] = context
      Thread.current[:arm] = true
      begin
        Timeout.timeout(0.2) { context.set_data(OpenStruct.new(data_future: data, success?: true)) }
      rescue Timeout::Error
        nil
      ensure
        Thread.current[:arm] = nil
        Thread.current[:fired] = nil
      end
      Timeout.timeout(5) { holder[:locker].join }

      expect(context.instance_variable_get(:@building_threads)).to be_empty
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      context.wait_until_ready(0.3)
      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).to be >= 0.25
    end

    # The interrupt is queued under a mask from a hook on the first line of
    # build_state's cleanup, and is delivered before that line runs: the
    # window before any cleanup there could be masked. The same thread then
    # waits for readiness, which must block rather than return as a builder,
    # or builds again, which must leave it unregistered afterwards.
    [[false, false], [true, false], [false, true], [true, true]].each do |rebuild, in_fiber|
      it "does not treat a thread as a builder after an interrupt lands as its build cleanup starts#{rebuild ? " and it builds again" : ""}#{in_fiber ? " in a fiber that then ends" : ""}" do
        context_config = ContextConfig.create
        context_config.set_units(units)
        context = Context.create_async(clock, context_config, data_provider, event_handler, event_logger,
                                       variable_parser, audience_matcher)
        source, first = Context.instance_method(:build_state).source_location
        lines = File.readlines(source)
        cleanup = (first...lines.size).find { |i| lines[i].strip == "ensure" }
        expect(cleanup).not_to be_nil, "build_state no longer has an ensure"
        cleanup_line = cleanup + 2
        worker = Thread.new do
          me = Thread.current
          trace = TracePoint.new(:line) do |tp|
            # A thread variable, not a fiber-local: the build may run in a fiber.
            next unless tp.path == source && tp.lineno == cleanup_line && me.thread_variable_get(:arm)

            me.thread_variable_set(:arm, false)
            Thread.handle_interrupt(Object => :never) { Thread.new { me.raise(RuntimeError, "async") }.join }
          end
          trace.enable
          me.thread_variable_set(:arm, true)
          build = lambda do
            context.set_data(OpenStruct.new(data_future: data, success?: true))
            :completed
          rescue RuntimeError => e
            e.message
          end
          # A build interrupted in a fiber leaves an entry naming that fiber;
          # once it has ended, the entry is stale from the thread's own fiber.
          outcome = begin
            in_fiber ? Fiber.new { build.call }.resume : build.call
          ensure
            trace.disable
          end
          waited = nil
          if rebuild
            context.set_data(OpenStruct.new(data_future: data, success?: true))
          else
            started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
            context.wait_until_ready(0.3)
            waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
          end
          [outcome, waited, context.instance_variable_get(:@building_threads).key?(me)]
        end
        outcome, waited, still_registered = Timeout.timeout(5) { worker.value }

        expect(outcome).to eq("async")
        expect(waited).to be >= 0.25 unless rebuild
        expect(still_registered).to be false
      end
    end

    it "finalize still raises a real rejection when recovery lands as its flush starts" do
      refresh_in = Queue.new
      refresh_out = Queue.new
      ready_data = data
      provider = Object.new
      provider.define_singleton_method(:context_data) do
        refresh_in << true
        refresh_out.pop
        OpenStruct.new(data_future: ready_data, success?: true)
      end
      # Only the first send is rejected: finalize must raise it rather than let
      # its second pass send the batch and seal.
      sends = 0
      handler = Object.new
      handler.define_singleton_method(:publish) do |_context, _event|
        sends += 1
        sends == 1 ? OpenStruct.new(exception: Exception.new("REJECTED"), success?: false) : OpenStruct.new(success?: true)
      end
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, provider, handler, event_logger,
                                     variable_parser, audience_matcher)
      refresher = Thread.new { context.refresh }
      Timeout.timeout(5) { refresh_in.pop }
      context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil))
      context.track("goal1", nil)
      # The context is failed when finalize starts; the refresh recovers just as
      # its flush begins, so that flush sends the goal and is rejected.
      original = context.method(:flush)
      allow(context).to receive(:flush) do |**kwargs|
        if kwargs[:sealing] && refresher.alive?
          refresh_out << true
          Timeout.timeout(5) { refresher.join }
        end
        original.call(**kwargs)
      end
      begin
        expect(context.failed?).to be true
        expect { Timeout.timeout(5) { context.finalize } }.to raise_error(StandardError, "REJECTED")
      ensure
        refresh_out << true
        refresher.join(5) || refresher.kill
      end
      expect(context.finalized?).to be false
      expect(context.pending_count).to eq(1)
    end

    it "finalize does not raise the load error when the initial fetch fails during its flush" do
      handler = Object.new
      handler.define_singleton_method(:publish) { |_context, _event| OpenStruct.new(success?: true) }
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider, handler, event_logger,
                                     variable_parser, audience_matcher)
      context.track("before", nil)
      original = context.method(:flush)
      allow(context).to receive(:flush) do |**kwargs|
        unless Thread.current[:failed_once]
          Thread.current[:failed_once] = true
          Thread.new { context.set_data(OpenStruct.new(exception: failure, success?: false, data_future: nil)) }.join(5)
        end
        original.call(**kwargs)
      end

      expect { Timeout.timeout(5) { context.finalize } }.not_to raise_error
      expect(context.finalized?).to be true
    ensure
      Thread.current[:failed_once] = nil
    end

    it "wakes a waiter when a refresh supplies the first data" do
      context_config = ContextConfig.create
      context_config.set_units(units)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)
      # Signal from the condition-variable wait itself, so the refresh runs only
      # once the waiter is really waiting; the waiter has no timeout of its own,
      # so only a broadcast can wake it.
      waiting = Queue.new
      condvar = context.instance_variable_get(:@ready_condvar)
      allow(condvar).to receive(:wait).and_wrap_original do |original, *args|
        waiting << true
        original.call(*args)
      end
      waiter = Thread.new { context.wait_until_ready }
      begin
        Timeout.timeout(5) { waiting.pop }
        context.refresh
        expect(waiter.join(5)).to eq(waiter)
        expect(context.ready?).to be true
      ensure
        waiter.kill if waiter.alive?
      end
    end
  end

  describe "Context#wait_until_ready" do
    it "returns immediately when already ready" do
      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      data_future = data_provider.context_data

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create(clock, context_config, data_future, data_provider,
                               event_handler, event_logger, variable_parser, audience_matcher)

      start = Time.now
      context.wait_until_ready
      elapsed = Time.now - start

      expect(context.ready?).to be true
      expect(elapsed).to be < 0.1
    end

    it "blocks until data arrives from background thread" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      waiter = Thread.new do
        context.wait_until_ready
        context.ready?
      end
      Thread.pass until waiter.status == "sleep" || !waiter.alive?
      expect([waiter.alive?, context.ready?]).to eq([true, false])

      context.set_data(OpenStruct.new(data_future: data, success?: true))

      expect(waiter.join(5)&.value).to be true
    end

    it "respects timeout and returns even if not ready" do
      context_config = ContextConfig.create
      context_config.set_units(units)

      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      context = Context.create_async(clock, context_config, data_provider,
                                     event_handler, event_logger, variable_parser, audience_matcher)

      start = Time.now
      context.wait_until_ready(0.1)
      elapsed = Time.now - start

      expect(context.ready?).to be false
      expect(elapsed).to be >= 0.09
      expect(elapsed).to be < 2
    end

    it "returns self for chaining" do
      data_provider = DefaultContextDataProvider.new(fast_client_mock)
      data_future = data_provider.context_data

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Context.create(clock, context_config, data_future, data_provider,
                               event_handler, event_logger, variable_parser, audience_matcher)

      result = context.wait_until_ready
      expect(result).to eq(context)
    end
  end

  describe "Absmartly.create_context_async" do
    after do
      Absmartly.endpoint = nil
      Absmartly.api_key = nil
      Absmartly.application = nil
      Absmartly.environment = nil
      Absmartly.event_logger = nil
      Absmartly.instance_variable_set(:@sdk, nil)
      Absmartly.instance_variable_set(:@sdk_config, nil)
    end

    it "creates an async context via the module interface" do
      allow(Client).to receive(:create).and_return(fast_client_mock)

      Absmartly.configure_client do |config|
        config.endpoint = "https://test.absmartly.io/v1"
        config.api_key = "test-key"
        config.application = "test-app"
        config.environment = "test"
      end

      context_config = ContextConfig.create
      context_config.set_units(units)

      context = Absmartly.create_context_async(context_config)
      expect(context).to be_a(Context)

      context.wait_until_ready
      expect(context.ready?).to be true
    end
  end
end
