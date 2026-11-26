# frozen_string_literal: true

require "json"
require "open3"
require "rbconfig"
require "a_b_smartly"
require "a_b_smartly_config"
require "context_event_handler"
require "json/experiment"
require "default_context_event_handler"
require "client"
require "client_config"
require "context_data_result"
require "context_config"

RSpec.describe "Backwards Compatibility" do
  # Run in a fresh process so constants loaded by other specs can't hide a
  # missing require.
  def run_ruby(script)
    lib = File.expand_path("../lib", __dir__)
    Open3.capture3(RbConfig.ruby, "-W:no-deprecated", "-I", lib, "-e", script)
  end

  # Fiber.current and Fiber#alive? need require "fiber" before Ruby 3.1.
  # A dependency (logger) may load it, but the library must not rely on that.
  it "requires fiber itself where it uses Fiber.current" do
    lib = File.expand_path("../lib", __dir__)
    users = Dir[File.join(lib, "**/*.rb")].select { |f| File.read(f, encoding: "UTF-8").match?(/Fiber\.current|\.alive\?/) }
    expect(users).not_to be_empty
    users.each do |file|
      expect(File.read(file, encoding: "UTF-8")).to match(/^require "fiber"$/), "#{file} uses Fiber.current without require \"fiber\""
    end
  end

  it "defines the public v1.3.0 classes after only require \"absmartly\"" do
    out, err, status = run_ruby(<<~RUBY)
      require "absmartly"
      class MyPublisher < ContextEventHandler
        def publish(context, event); end
      end
      p [MyPublisher.ancestors.include?(Absmartly::ContextPublisher), DefaultContextEventHandler == Absmartly::DefaultContextPublisher]
    RUBY
    expect([out, status.success?]).to eq(["[true, true]\n", true]), err
  end

  it "defines no top-level SDK, SDKConfig or TypeUtils that could clash with application constants" do
    out, err, status = run_ruby(<<~RUBY)
      module SDK; end
      class SDKConfig; end
      module TypeUtils; end
      require "absmartly"
      p [SDK.class, SDKConfig.superclass, TypeUtils.methods(false), Absmartly::TypeUtils.numeric?(1)]
    RUBY
    expect([out, status.success?]).to eq(["[Module, Object, [], true]\n", true]), err
  end

  # The top-level constants the SDK's own files define after `require
  # "absmartly"`, exactly as the published 1.3.0 gem defined them. Additions
  # live under Absmartly so they can't clash with an application's classes;
  # ContextDataResult and PublishError were top-level only on unreleased main.
  V1_3_0_TOP_LEVEL = %i[
    ABSmartly ABSmartlyConfig Absmartly AndCombinator Assignment Attribute AudienceDeserializer AudienceMatcher
    BinaryOperator BooleanCombinator Client ClientConfig Context ContextConfig ContextCustomFieldValues ContextData
    ContextDataDeserializer ContextDataProvider ContextEventHandler ContextEventLogger ContextEventSerializer
    CustomFieldValue DefaultAudienceDeserializer DefaultContextDataDeserializer DefaultContextDataProvider
    DefaultContextEventHandler DefaultContextEventSerializer DefaultHttpClient DefaultHttpClientConfig
    DefaultVariableParser EMPTY_LIST EMPTY_MAP EqualsOperator Evaluator Experiment ExperimentApplication
    ExperimentVariables ExperimentVariant Exposure ExprEvaluator GoalAchievement GreaterThanOperator
    GreaterThanOrEqualOperator Hashing HttpClient IllegalStateException InOperator JsonExpr LessThanOperator
    LessThanOrEqualOperator MatchOperator NilOperator NotOperator OrCombinator PublishEvent
    ScheduledThreadPoolExecutor UnaryOperator Unit ValueOperator VarOperator VariableParser VariantAssigner
  ].freeze

  # spec/compat/top_level_surface.rb loads the SDK, drives every public entry
  # point against a local collector (fetch, treatment, variables, track, an
  # accepted and a rejected publish, refresh, async and pre-fetched contexts,
  # close), then reports the top-level surface. Either load order must leave
  # exactly the 1.3.0 names, add none on use, and leave an application's own
  # classes and Object's ancestors untouched.
  %w[sdk_first app_first].each do |mode|
    it "keeps the published 1.3.0 top-level surface through real use (#{mode.tr("_", " ")})" do
      lib = File.expand_path("../lib", __dir__)
      script = File.expand_path("compat/top_level_surface.rb", __dir__)
      command = [RbConfig.ruby, "-W:no-deprecated", "-I", lib, script, lib, mode, *V1_3_0_TOP_LEVEL.map(&:to_s)]
      out = err = status = nil
      # A hang fails the example instead of stalling the run.
      Open3.popen3(*command) do |stdin, stdout, stderr, wait|
        stdin.close
        readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
        unless wait.join(60)
          Process.kill("KILL", wait.pid)
          raise "top_level_surface.rb did not finish within 60s"
        end
        out, err = readers.map(&:value)
        status = wait.value
      end
      expect(status.success?).to be(true), err
      report = JSON.parse(out.lines.last)
      expect(report).to eq(
        "sdk_owned" => V1_3_0_TOP_LEVEL.map(&:to_s).sort, "unexpected" => [], "missing" => [],
        "added_by_use" => [], "ancestors_changed" => false, "reachable" => [], "app_intact" => true,
        "working" => true
      )
    end
  end

  it "loads next to application classes named like the SDK's additions without replacing them" do
    out, err, status = run_ruby(<<~RUBY)
      class PublishError < RuntimeError; end
      class SemverComparator; end
      class ContextDataResult; end
      require "absmartly"
      class Base; end
      class ContextPublisher < Base
        def publish(*); :mine; end
      end
      class DefaultContextPublisher
        def publish(*); :mine_too; end
      end
      p [PublishError.superclass, SemverComparator.class, ContextPublisher.superclass,
         ContextPublisher == ContextEventHandler, DefaultContextPublisher.superclass,
         DefaultContextEventHandler.new(Object.new).respond_to?(:publish) &&
           DefaultContextEventHandler.instance_method(:publish).owner,
         Absmartly::PublishError.superclass,
         ABSmartly.new("https://x/v1", api_key: "k", application: "a", environment: "e")
           .context_event_handler.class]
    RUBY
    expect([out, status.success?])
      .to eq(["[RuntimeError, Class, Base, false, Object, DefaultContextEventHandler, StandardError, DefaultContextEventHandler]\n",
              true]), err
  end

  it "ContextEventHandler is still the v1.3.0 class, aliased as Absmartly::ContextPublisher without a warning" do
    original = Warning[:deprecated]
    Warning[:deprecated] = true
    expect { expect(Absmartly::ContextPublisher).to eq(ContextEventHandler) }.not_to output.to_stderr
    expect(ContextEventHandler.name).to eq("ContextEventHandler")
  ensure
    Warning[:deprecated] = original
  end

  it "converts experiment collections for every supported key form" do
    applications = [{ name: "website" }]
    variants = [{ name: "A", config: nil }]
    fields = [{ name: "country", value: "US", type: "string" }]
    [
      { applications: applications, variants: variants, customFieldValues: fields },
      { "applications" => applications, "variants" => variants, "custom_field_values" => fields }
    ].each do |args|
      experiment = Experiment.new(args)
      expect(experiment.applications.first).to be_a(ExperimentApplication)
      expect(experiment.variants.first).to be_a(ExperimentVariant)
      expect(experiment.custom_field_values.first).to be_a(CustomFieldValue)
    end
  end

  it "reads string-keyed nested objects passed to Experiment.new" do
    experiment = Experiment.new(
      "variants" => [{ "name" => "A", "config" => "{\"a\":1}" }],
      "applications" => [{ "name" => "website" }],
      "customFieldValues" => [{ "type" => "string", "value" => "US", "name" => "country" }]
    )

    expect(experiment.variants).to eq([ExperimentVariant.new("A", "{\"a\":1}")])
    expect(experiment.applications).to eq([ExperimentApplication.new("website")])
    expect(experiment.custom_field_values).to eq([CustomFieldValue.new("country", "US", "string")])
  end

  it "parses custom field values whose type is given as a Symbol, as in v1.3.0" do
    out, err, status = run_ruby(<<~RUBY)
      require "absmartly"
      data = ContextData.new([{ id: 1, name: "exp", unitType: "session_id", iteration: 1, split: [1],
                                trafficSplit: [1], fullOnVariant: 0, seedHi: 0, seedLo: 0,
                                trafficSeedHi: 0, trafficSeedLo: 0,
                                variants: [{ name: "A", config: nil }],
                                customFieldValues: [{ name: "j", value: '{"a":1}', type: :json },
                                                    { name: "n", value: "7", type: :number },
                                                    { name: "b", value: "true", type: :boolean }] }])
      config = ContextConfig.create
      config.set_unit("session_id", "u1")
      context = Context.create(Time.at(0), config, Struct.new(:data_future, :success?).new(data, true), nil,
                               nil, nil, DefaultVariableParser.new,
                               AudienceMatcher.new(DefaultAudienceDeserializer.new))
      print Marshal.dump([context.custom_field_value("exp", "j"), context.custom_field_value("exp", "n"),
                          context.custom_field_value("exp", "b")]).unpack1("H*")
    RUBY

    expect(status).to be_success, err
    expect(Marshal.load([out].pack("H*"))).to eq([{ a: 1 }, 7, true])
  end

  it "prefers the symbol key when a nested object has both key styles" do
    experiment = Experiment.new(variants: [{ name: "sym", "name" => "str", config: nil }])

    expect(experiment.variants.first.name).to eq("sym")

    experiment = Experiment.new(variants: [{ name: nil, "name" => "str", config: nil }])

    expect(experiment.variants.first.name).to be_nil
  end

  it "DefaultContextEventHandler is still the v1.3.0 class, aliased as Absmartly::DefaultContextPublisher without a warning" do
    original = Warning[:deprecated]
    Warning[:deprecated] = true
    expect { expect(Absmartly::DefaultContextPublisher).to eq(DefaultContextEventHandler) }.not_to output.to_stderr
    expect(DefaultContextEventHandler.name).to eq("DefaultContextEventHandler")
    expect(DefaultContextEventHandler.superclass).to eq(ContextEventHandler)
  ensure
    Warning[:deprecated] = original
  end

  it "the default publisher is a DefaultContextEventHandler and builds without warnings" do
    original = Warning[:deprecated]
    Warning[:deprecated] = false
    client = instance_double(Client)
    expect { @handler = Object.const_get(:DefaultContextEventHandler).new(client) }.not_to output.to_stderr
    config = ABSmartlyConfig.create
    config.client = client
    expect(ABSmartly.create(config).context_event_handler).to be_a(Object.const_get(:DefaultContextEventHandler))
    expect(@handler).to be_a(Absmartly::DefaultContextPublisher)
  ensure
    Warning[:deprecated] = original
  end

  it "ignores unknown experiment fields without writing to stderr" do
    expect {
      experiment = Experiment.new(id: 1, name: "exp", holdoutIds: [1, 2], someNewField: true)
      expect(experiment.name).to eq("exp")
    }.not_to output.to_stderr
  end

  it "does not load ostruct, which is not a default gem from Ruby 3.5" do
    lib = File.expand_path("../lib", __dir__)
    expect(Dir[File.join(lib, "**/*.rb")].grep_v(/_spec/).select { |f| File.read(f, encoding: "UTF-8").match?(/require ["']ostruct["']|OpenStruct/) })
      .to be_empty
  end

  describe "ABSmartly.new" do
    it "accepts a duck-typed config object" do
      client = instance_double(Client)
      config = Struct.new(:context_data_provider, :context_event_handler, :context_event_logger,
                          :variable_parser, :audience_deserializer, :scheduler, :client)
                     .new(nil, nil, nil, nil, nil, nil, client)

      sdk = ABSmartly.new(config)

      expect(sdk.client).to be(client)
      expect(sdk.context_data_provider).to be_a(DefaultContextDataProvider)
    end

    it "accepts a duck-typed config that responds to to_hash" do
      client = instance_double(Client)
      config = Struct.new(:context_data_provider, :context_event_handler, :context_event_logger,
                          :variable_parser, :audience_deserializer, :scheduler, :client) do
        def to_hash
          to_h
        end
      end.new(nil, nil, nil, nil, nil, nil, client)

      expect(ABSmartly.new(config).client).to be(client)
    end

    it "rejects unknown and extra arguments like keyword parameters would" do
      expect { ABSmartly.new("https://x", api_key: "k", bogus: 1) }
        .to raise_error(ArgumentError, "unknown keyword: :bogus")
      expect { ABSmartly.new("https://x", "y") }.to raise_error(ArgumentError, /wrong number of arguments/)
    end

    it "accepts an rspec instance_double of the config" do
      client = instance_double(Client)
      config = instance_double(ABSmartlyConfig, context_data_provider: nil, context_event_handler: nil,
                               context_event_logger: nil, variable_parser: nil, audience_deserializer: nil,
                               scheduler: nil, client: client)

      expect(ABSmartly.new(config).client).to be(client)
    end

    it "runs a subclass's initialize" do
      subclass = Class.new(ABSmartly) do
        attr_reader :extra

        def initialize(config)
          super(config)
          @extra = 1
        end
      end
      config = ABSmartlyConfig.create
      config.client = instance_double(Client)

      sdk = subclass.new(config)

      expect([sdk.class.superclass, sdk.extra]).to eq([ABSmartly, 1])
    end
  end

  describe "Client" do
    let(:config) do
      ClientConfig.create.tap do |c|
        c.endpoint = "https://localhost/v1"
        c.api_key = "test-api-key"
        c.application = "website"
        c.environment = "dev"
      end
    end

    it "keeps the public headers accessor" do
      client = Client.new(config, instance_double(HttpClient))

      expect(client.headers[:"X-API-Key"]).to eq("test-api-key")
      client.headers = client.headers.merge("Proxy-Authorization": "Basic abc")
      expect(client.headers[:"Proxy-Authorization"]).to eq("Basic abc")
      expect(client.inspect).not_to include("test-api-key")
    end

    it "fails a context without writing to stderr when the fetch fails or the event logger raises" do
      http_client = instance_double(HttpClient)
      allow(http_client).to receive(:get).and_return(
        DefaultHttpClient.default_response(503, "Service Unavailable", nil, nil),
        DefaultHttpClient.default_response(200, "OK", "application/json", "not json")
      )
      logger = Class.new do
        def handle_event(_type, _data)
          raise "logger bug"
        end
      end.new
      sdk_config = ABSmartlyConfig.create
      sdk_config.client = Client.new(config, http_client)
      sdk_config.context_event_logger = logger
      sdk = ABSmartly.create(sdk_config)
      context_config = ContextConfig.create
      context_config.set_unit(:session_id, "abc")

      expect {
        2.times { expect(sdk.create_context(context_config).failed?).to be(true) }
      }.not_to output.to_stderr
    end

    it "returns a separate immutable result per context_data call" do
      http_client = instance_double(HttpClient)
      deserializer = instance_double(ContextDataDeserializer)
      config.context_data_deserializer = deserializer
      client = Client.new(config, http_client)
      ok = DefaultHttpClient.default_response(200, "OK", "application/json", "{}")
      failed = DefaultHttpClient.default_response(503, "Service Unavailable", nil, nil)
      allow(http_client).to receive(:get).and_return(ok, failed)
      data = ContextData.new
      allow(deserializer).to receive(:deserialize).and_return(data)

      first = client.context_data
      second = client.context_data

      expect(first).not_to be(client)
      expect(first).to be_frozen
      expect([first.success?, first.data_future, first.exception]).to eq([true, data, nil])
      expect([second.success?, second.data_future, second.exception.message])
        .to eq([false, nil, "Service Unavailable"])
      expect([client.success?, client.data_future, client.exception.message])
        .to eq([false, nil, "Service Unavailable"])
    end
  end
end
