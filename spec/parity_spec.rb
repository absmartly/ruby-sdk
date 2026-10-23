# frozen_string_literal: true

require "context"
require "context_config"
require "default_context_data_deserializer"
require "default_variable_parser"
require "default_audience_deserializer"
require "default_context_data_provider"
require "context_event_handler"
require "context_event_logger"
require "audience_matcher"
require "hashing"
require "variant_assigner"
require "json_expr/json_expr"
require "client"
require "client_config"
require "socket"

# Behaviors aligned with the JavaScript SDK (the reference implementation).
RSpec.describe "JavaScript SDK parity" do
  describe "UTF-8 unit encoding" do
    # Shared cross-SDK vectors, validated against the JavaScript SDK's
    # stringToUint8Array / hashUnit.
    vectors = {
      "user\u{1F600}id" => [[117, 115, 101, 114, 240, 159, 152, 128, 105, 100], "nnPMxN6wY36LGRnuJ6jZrw"],
      "\u{1F600}" => [[240, 159, 152, 128], "KgLqw51xanDs83V5GFkntg"],
      "\u{2000B}" => [[240, 160, 128, 139], "8mWvgvNGn-DZqb6Ft0HVjA"],
      "a€\u{1D11E}z" => [[97, 226, 130, 172, 240, 157, 132, 158, 122], "AGGq8R9K1XjO77q33izhLg"],
      "\u{1F1F5}\u{1F1F9}" => [[240, 159, 135, 181, 240, 159, 135, 185], "1RRpVphazpblARsm5DaSkg"]
    }
    lone_surrogate_bytes = [97, 98, 239, 191, 189, 99, 100]
    lone_surrogate_hash = "jvDxBUzS9Tdsml3QQStWSg"

    vectors.each do |value, (bytes, hash)|
      it "encodes #{value.inspect} as standard 4-byte UTF-8 and hashes it" do
        expect(Hashing.to_utf8(value).bytes).to eq(bytes)
        expect(Hashing.hash_unit(value)).to eq(hash)
      end

      it "hashes #{value.inspect} the same from UTF-16 and from CESU-8 bytes" do
        expect(Hashing.hash_unit(value.encode("UTF-16LE"))).to eq(hash)
        cesu = value.encode("UTF-16BE").unpack("n*").map { |u| [u].pack("U") }.join.b
        expect(Hashing.hash_unit(cesu.force_encoding("UTF-8"))).to eq(hash)
      end
    end

    it "replaces a lone surrogate in a UTF-16 string with U+FFFD" do
      utf16 = "ab".encode("UTF-16LE") + [0xD83D].pack("v").force_encoding("UTF-16LE") + "cd".encode("UTF-16LE")
      expect(Hashing.to_utf8(utf16).bytes).to eq(lone_surrogate_bytes)
      expect(Hashing.hash_unit(utf16)).to eq(lone_surrogate_hash)
    end

    it "replaces a lone surrogate encoded as UTF-8 bytes with a single U+FFFD" do
      wtf8 = "ab\xED\xA0\xBDcd".dup.force_encoding("UTF-8")
      expect(Hashing.to_utf8(wtf8).bytes).to eq(lone_surrogate_bytes)
      expect(Hashing.hash_unit(wtf8)).to eq(lone_surrogate_hash)
    end

    it "replaces other invalid bytes with U+FFFD" do
      expect(Hashing.to_utf8("a\xFFb".dup.force_encoding("UTF-8")).bytes).to eq([97, 239, 191, 189, 98])
    end

    it "assigns non-BMP units like the JavaScript VariantAssigner" do
      {
        "\u{1F600}" => 1,
        "\u{1F1F5}\u{1F1F9}" => 0,
        "a€\u{1D11E}z" => 1,
        "user\u{1F600}id" => 0
      }.each do |unit, variant|
        expect(VariantAssigner.new(unit).assign([0.5, 0.5], 3603583, 233373918)).to eq(variant), unit
      end
    end
  end

  describe "operators" do
    let(:expr) { JsonExpr.new }

    def value(x)
      { value: x }
    end

    it "eq(null, null) is null" do
      expect(expr.evaluate_expr({ eq: [value(nil), value(nil)] }, {})).to be_nil
    end

    it "in looks up keys of an object haystack, including symbolized audience attributes" do
      vars = JSON.parse('{"h":{"a":1}}', symbolize_names: true)
      expect(expr.evaluate_expr({ in: [{ var: "h" }, value("a")] }, vars)).to be(true)
      expect(expr.evaluate_expr({ in: [{ var: "h" }, value("b")] }, vars)).to be(false)
    end

    it "in is haystack-first and converts a non-string needle for a string haystack" do
      expect(expr.evaluate_expr({ in: [value("abc1"), value(1)] }, {})).to be(true)
      expect(expr.evaluate_expr({ in: [value("abc"), value([1])] }, {})).to be(false)
      expect(expr.evaluate_expr({ in: [value(5), value(1)] }, {})).to be_nil
    end

    it "match returns null for an invalid pattern" do
      expect(expr.evaluate_expr({ match: [value("abc"), value("(")] }, {})).to be_nil
    end
  end

  describe "context lifecycle" do
    let(:descr) { DefaultContextDataDeserializer.new }
    let(:json) { resource("context.json") }
    let(:data) { descr.deserialize(json, 0, json.length) }
    let(:clock) { Time.at(1620000000) }
    let(:ready_future) { OpenStruct.new(data_future: data, success?: true) }
    let(:failure) { Exception.new("FAILED") }
    let(:failure_future) { OpenStruct.new(exception: failure, success?: false, data_future: nil) }
    let(:ok_future) { OpenStruct.new(success?: true) }
    let(:data_provider) { instance_double(ContextDataProvider, context_data: ready_future) }
    let(:handler) { instance_double(ContextEventHandler) }
    let(:events) { [] }
    let(:logger) do
      log = events
      Class.new(ContextEventLogger) do
        define_method(:handle_event) { |event, data| log << [event, data] }
      end.new
    end

    def make_context(future = ready_future, event_logger: logger)
      config = ContextConfig.create
      config.set_units(session_id: "e791e240fcd3df7d238cfc285f475e8152fcc0ec")
      Context.create(clock, config, future, data_provider, handler, event_logger,
                     DefaultVariableParser.new, AudienceMatcher.new(DefaultAudienceDeserializer.new))
    end

    it "keeps the context open and the events queued when the final publish fails" do
      allow(handler).to receive(:publish).and_return(failure_future)
      context = make_context
      context.track("goal1", nil)

      result = context.close

      expect(result.exception).to eq(failure)
      expect(context.closed?).to be(false)
      expect(context.finalizing?).to be(false)
      expect(context.pending_count).to eq(1)
      expect(events.map(&:first)).not_to include(ContextEventLogger::EVENT_TYPE::FINALIZE)

      allow(handler).to receive(:publish).and_return(ok_future)
      expect(context.close).to be_nil
      expect(context.closed?).to be(true)
      expect(context.pending_count).to eq(0)
      expect(handler).to have_received(:publish).twice
      expect(events.map(&:first)).to include(ContextEventLogger::EVENT_TYPE::FINALIZE)
    end

    it "emits the finalize event under the name \"finalize\"" do
      allow(handler).to receive(:publish).and_return(ok_future)
      context = make_context
      context.close
      expect(events.last).to eq(["finalize", nil])
    end

    it "closes a failed context, discarding its events" do
      context = make_context(failure_future)
      context.track("goal1", nil)
      context.close
      expect(context.closed?).to be(true)
      expect(context.pending_count).to eq(0)
    end

    it "treats refresh of a failed context as a successful no-op" do
      context = make_context(failure_future)
      expect(context.refresh).to be_nil
      expect(data_provider).not_to have_received(:context_data)
      expect(context.failed?).to be(true)
    end

    it "keeps a ready context usable after a failed refresh" do
      context = make_context
      allow(data_provider).to receive(:context_data).and_return(failure_future)
      expect(context.refresh).to eq(failure)
      expect(context.failed?).to be(false)
      expect(context.experiments).to eq(data.experiments.map(&:name))
    end

    it "does not let a raising event logger break treatment or publish" do
      raising = Class.new(ContextEventLogger) do
        def handle_event(_event, _data)
          raise "logger boom"
        end
      end.new
      allow(handler).to receive(:publish).and_return(ok_future)
      context = nil
      expect { context = make_context(event_logger: raising) }.not_to raise_error
      expect { context.treatment("exp_test_ab") }.not_to raise_error
      expect(context.publish).to eq(ok_future)
      expect(context.pending_count).to eq(0)
    end

    it "keeps a cached assignment when a re-evaluated audience is indeterminate" do
      exp = data.experiments.find { |e| e.name == "exp_test_ab" }
      exp.audience = '{"no_filter":true}'
      allow(handler).to receive(:publish).and_return(ok_future)
      context = make_context
      first = context.treatment("exp_test_ab")
      context.set_attribute("age", 25)
      expect(context.treatment("exp_test_ab")).to eq(first)
      expect(context.pending_count).to eq(1)
    end

    it "normalizes a unit to UTF-8 before comparing and hashing it" do
      config = ContextConfig.create
      context = Context.create(clock, config, ready_future, data_provider, handler, logger,
                               DefaultVariableParser.new, AudienceMatcher.new(DefaultAudienceDeserializer.new))
      context.set_unit(:user_id, "user\u{1F600}id".encode("UTF-16LE"))
      expect(context.get_unit(:user_id).encoding).to eq(Encoding::UTF_8)
      expect { context.set_unit(:user_id, "user\u{1F600}id") }.not_to raise_error
    end
  end

  describe "transport" do
    # Answers each request with the next status from the list.
    def with_server(statuses)
      server = TCPServer.new("127.0.0.1", 0)
      seen = []
      thread = Thread.new do
        statuses.each do |status|
          client = server.accept
          request = client.gets
          length = 0
          while (line = client.gets) && line != "\r\n"
            length = line.split(":", 2)[1].to_i if line.downcase.start_with?("content-length")
          end
          client.read(length) if length.positive?
          seen << request.split(" ").first
          body = '{"experiments":[]}'
          client.write("HTTP/1.1 #{status} X\r\nContent-Type: application/json\r\n" \
                       "Content-Length: #{body.bytesize}\r\nConnection: close\r\n\r\n#{body}")
          client.close
        end
      end
      yield "http://127.0.0.1:#{server.addr[1]}", seen
    ensure
      thread&.kill
      server&.close
    end

    def client_for(endpoint)
      config = ClientConfig.create
      config.endpoint = endpoint
      config.api_key = "k"
      config.application = "a"
      config.environment = "e"
      config.retry_interval = 0.01
      Client.create(config)
    end

    it "retries a 5xx publish and reports success" do
      with_server([503, 200]) do |endpoint, seen|
        event = PublishEvent.new
        event.hashed = true
        event.units = []
        response = client_for(endpoint).publish(event)
        expect(response).not_to be_a(Exception)
        expect(seen).to eq(%w[PUT PUT])
      end
    end

    it "retries a 5xx context fetch" do
      with_server([500, 200]) do |endpoint, seen|
        client = client_for(endpoint).context_data
        expect(client.exception).to be_nil
        expect(seen).to eq(%w[GET GET])
      end
    end

    it "does not retry a 4xx publish" do
      with_server([400, 200]) do |endpoint, seen|
        event = PublishEvent.new
        event.hashed = true
        event.units = []
        expect(client_for(endpoint).publish(event)).to be_a(Exception)
        expect(seen).to eq(%w[PUT])
      end
    end

    it "fails the context fetch instead of raising on a connection error" do
      server = TCPServer.new("127.0.0.1", 0)
      port = server.addr[1]
      server.close
      config = ClientConfig.create
      config.endpoint = "http://127.0.0.1:#{port}"
      config.api_key = "k"
      config.application = "a"
      config.environment = "e"
      config.max_retries = 0
      client = nil
      expect { client = Client.create(config).context_data }.not_to raise_error
      expect(client.success?).to be(false)
      expect(client.exception).not_to be_nil
    end
  end
end
