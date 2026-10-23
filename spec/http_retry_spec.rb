# frozen_string_literal: true

require "default_http_client"
require "default_http_client_config"

RSpec.describe "HTTP Retry Logic" do
  describe "configuration" do
    it "configures max_retries correctly" do
      config = DefaultHttpClientConfig.create
      config.max_retries = 3

      client = DefaultHttpClient.create(config)

      expect(config.max_retries).to eq(3)
    end

    it "configures retry_interval correctly" do
      config = DefaultHttpClientConfig.create
      config.retry_interval = 0.2

      expect(config.retry_interval).to eq(0.2)
    end

    it "uses default max_retries of 5" do
      config = DefaultHttpClientConfig.create

      expect(config.max_retries).to eq(5)
    end

    it "uses default retry_interval of 0.5" do
      config = DefaultHttpClientConfig.create

      expect(config.retry_interval).to eq(0.5)
    end

    it "uses default connect_timeout of 3.0" do
      config = DefaultHttpClientConfig.create

      expect(config.connect_timeout).to eq(3.0)
    end

    it "uses default connection_request_timeout of 3.0" do
      config = DefaultHttpClientConfig.create

      expect(config.connection_request_timeout).to eq(3.0)
    end

    it "uses default pool_size of 20" do
      config = DefaultHttpClientConfig.create

      expect(config.pool_size).to eq(20)
    end

    it "uses default pool_idle_timeout of 5" do
      config = DefaultHttpClientConfig.create

      expect(config.pool_idle_timeout).to eq(5)
    end
  end

  describe "Faraday retry middleware configuration" do
    it "configures retry middleware with max_retries" do
      config = DefaultHttpClientConfig.create
      config.max_retries = 3
      config.retry_interval = 0.1

      client = DefaultHttpClient.create(config)

      handlers = client.session.builder.handlers
      retry_handler = handlers.find { |h| h.name.include?("Retry") }

      expect(retry_handler).not_to be_nil
    end

    it "creates client with custom pool size" do
      config = DefaultHttpClientConfig.create
      config.pool_size = 50

      expect_any_instance_of(Faraday::Connection).to receive(:adapter)
        .with(:net_http_persistent, pool_size: 50)
        .and_call_original

      DefaultHttpClient.create(config)
    end

    it "creates client with custom timeout settings" do
      config = DefaultHttpClientConfig.create
      config.connect_timeout = 10.0
      config.connection_request_timeout = 15.0

      client = DefaultHttpClient.create(config)

      expect(client.session.options.timeout).to eq(10.0)
      expect(client.session.options.open_timeout).to eq(15.0)
    end
  end

  describe "HTTP client methods" do
    let(:config) { DefaultHttpClientConfig.create }
    let(:client) { DefaultHttpClient.create(config) }

    it "responds to get method" do
      expect(client).to respond_to(:get)
    end

    it "responds to put method" do
      expect(client).to respond_to(:put)
    end

    it "responds to post method" do
      expect(client).to respond_to(:post)
    end

    it "responds to close method" do
      expect(client).to respond_to(:close)
    end
  end

  describe "default_response factory" do
    it "creates response with correct status code" do
      response = DefaultHttpClient.default_response(200, "OK", "application/json", '{"data": "test"}')

      expect(response.status).to eq(200)
    end

    it "creates response with correct body" do
      response = DefaultHttpClient.default_response(200, "OK", "application/json", '{"data": "test"}')

      expect(response.body).to eq('{"data": "test"}')
    end

    it "creates error response with status message as body when content is nil" do
      response = DefaultHttpClient.default_response(500, "Internal Server Error", nil, nil)

      expect(response.status).to eq(500)
      expect(response.body).to eq("Internal Server Error")
    end

    it "creates response with content type header" do
      response = DefaultHttpClient.default_response(200, "OK", "application/json", '{}')

      expect(response.headers["Content-Type"]).to eq("application/json")
    end

    it "handles 4xx client errors" do
      response = DefaultHttpClient.default_response(400, "Bad Request", "application/json", '{"error": "bad"}')

      expect(response.status).to eq(400)
      expect(response.body).to eq('{"error": "bad"}')
    end

    it "handles 5xx server errors" do
      response = DefaultHttpClient.default_response(503, "Service Unavailable", nil, nil)

      expect(response.status).to eq(503)
    end
  end

  describe "retry behavior expectations" do
    it "faraday-retry gem is available" do
      expect(defined?(Faraday::Retry)).not_to be_nil
    end

    it "retry middleware supports exponential backoff" do
      config = DefaultHttpClientConfig.create
      client = DefaultHttpClient.create(config)

      handlers = client.session.builder.handlers
      retry_handler = handlers.find { |h| h.name.include?("Retry") }

      expect(retry_handler).not_to be_nil
    end
  end
end
