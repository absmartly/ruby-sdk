# frozen_string_literal: true

require "a_b_smartly"
require "context_config"
require "socket"
require "json"
require "uri"

# Hermetic integration test: spins up a real local HTTP server on an ephemeral
# port (stdlib TCPServer, no WEBrick dependency), points the SDK's client
# endpoint at it, and drives the PUBLIC SDK API so the real Faraday HTTP client
# performs a GET /context (create_context -> wait_until_ready) and a
# PUT /context (track -> publish). Asserts the wire contract.
class LocalTestServer
  attr_reader :port, :requests

  def initialize
    @server = TCPServer.new("127.0.0.1", 0)
    @port = @server.addr[1]
    @requests = []
    @mutex = Mutex.new
    @thread = Thread.new { serve }
  end

  def serve
    loop do
      client = @server.accept
      handle(client)
    rescue IOError, Errno::EBADF
      break
    end
  end

  def handle(client)
    request_line = client.gets
    return if request_line.nil?

    method, path, = request_line.split(" ")
    headers = {}
    while (line = client.gets) && line != "\r\n"
      key, value = line.split(":", 2)
      headers[key.strip.downcase] = value.strip if value
    end

    body = nil
    if (len = headers["content-length"]) && len.to_i.positive?
      body = client.read(len.to_i)
    end

    @mutex.synchronize do
      @requests << { method: method, path: path, headers: headers, body: body }
    end

    response_body = method == "GET" ? '{"experiments":[]}' : "{}"
    client.write("HTTP/1.1 200 OK\r\n")
    client.write("Content-Type: application/json\r\n")
    client.write("Content-Length: #{response_body.bytesize}\r\n")
    client.write("Connection: close\r\n")
    client.write("\r\n")
    client.write(response_body)
  ensure
    client.close rescue nil
  end

  def base_url
    "http://127.0.0.1:#{port}"
  end

  def stop
    @server.close rescue nil
    @thread.kill
  end
end

RSpec.describe "Local server integration (real HTTP)" do
  let(:server) { LocalTestServer.new }

  after { server.stop }

  it "performs a real GET /context and PUT /context against a local server" do
    sdk = ABSmartly.new(
      server.base_url,
      api_key: "test-api-key",
      application: "website",
      environment: "dev"
    )

    context_config = ContextConfig.create
    context_config.set_unit("user_id", "123456789")

    context = sdk.create_context(context_config)
    context.wait_until_ready

    # --- assert the real GET /context ---
    get_req = server.requests.find { |r| r[:method] == "GET" }
    expect(get_req).not_to be_nil
    uri = URI.parse(get_req[:path])
    expect(uri.path).to eq("/context")
    query = URI.decode_www_form(uri.query || "").to_h
    expect(query["application"]).to eq("website")
    expect(query["environment"]).to eq("dev")

    # --- queue an event then publish ---
    context.track("payment", { value: 99 })
    context.publish

    put_req = server.requests.find { |r| r[:method] == "PUT" }
    expect(put_req).not_to be_nil
    expect(URI.parse(put_req[:path]).path).to eq("/context")

    # --- headers ---
    h = put_req[:headers]
    expect(h["x-api-key"]).to eq("test-api-key")
    expect(h["x-application"]).to eq("website")
    expect(h["x-environment"]).to eq("dev")
    expect(h["x-application-version"]).to eq("0")
    expect(h["x-agent"]).not_to be_nil
    expect(h["x-agent"]).not_to be_empty
    expect(h["content-type"]).to include("application/json")

    # --- body ---
    body = JSON.parse(put_req[:body])
    expect(body).to have_key("hashed")
    expect(body["units"]).to be_an(Array)
    expect(body["units"]).not_to be_empty
    expect(body["units"].first).to have_key("type")
    expect(body["units"].first).to have_key("uid")
    expect(body).to have_key("publishedAt")
    expect(body["publishedAt"]).to be_a(Integer)
    expect(body["goals"]).to be_an(Array)
    expect(body["goals"]).not_to be_empty
    expect(body["goals"].first["name"]).to eq("payment")
  end
end
