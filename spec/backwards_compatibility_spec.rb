# frozen_string_literal: true

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

  it "defines the public v1.3.0 classes after only require \"absmartly\"" do
    out, err, status = run_ruby(<<~RUBY)
      require "absmartly"
      class MyPublisher < ContextEventHandler
        def publish(context, event); end
      end
      p [MyPublisher.ancestors.include?(ContextPublisher), DefaultContextEventHandler == DefaultContextPublisher]
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

  it "ContextEventHandler is a deprecated alias for ContextPublisher" do
    original = Warning[:deprecated]
    Warning[:deprecated] = true
    expect { expect(Object.const_get(:ContextEventHandler)).to eq(ContextPublisher) }
      .to output(/ContextEventHandler is deprecated/).to_stderr
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

  it "DefaultContextEventHandler is a deprecated alias for DefaultContextPublisher" do
    original = Warning[:deprecated]
    Warning[:deprecated] = true
    expect { expect(Object.const_get(:DefaultContextEventHandler)).to eq(DefaultContextPublisher) }
      .to output(/DefaultContextEventHandler is deprecated/).to_stderr
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
    expect(@handler).to be_a(DefaultContextPublisher)
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
    expect(Dir[File.join(lib, "**/*.rb")].grep_v(/_spec/).select { |f| File.read(f).match?(/require ["']ostruct["']|OpenStruct/) })
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
