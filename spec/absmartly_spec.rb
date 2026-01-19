# frozen_string_literal: true

RSpec.describe Absmartly do
  it "has a version number" do
    expect(Absmartly::VERSION).not_to be nil
  end

  describe ".configure_client" do
    after do
      Absmartly.endpoint = nil
      Absmartly.api_key = nil
      Absmartly.application = nil
      Absmartly.environment = nil
      Absmartly.connect_timeout = nil
      Absmartly.connection_request_timeout = nil
      Absmartly.retry_interval = nil
      Absmartly.max_retries = nil
    end

    it "sets HTTP config options" do
      Absmartly.configure_client do |config|
        config.endpoint = "https://test.absmartly.io/v1"
        config.api_key = "test-api-key"
        config.application = "website"
        config.environment = "development"
        config.connect_timeout = 5.0
        config.connection_request_timeout = 10.0
        config.retry_interval = 1.0
        config.max_retries = 3
      end

      expect(Absmartly.endpoint).to eq("https://test.absmartly.io/v1")
      expect(Absmartly.api_key).to eq("test-api-key")
      expect(Absmartly.application).to eq("website")
      expect(Absmartly.environment).to eq("development")
      expect(Absmartly.connect_timeout).to eq(5.0)
      expect(Absmartly.connection_request_timeout).to eq(10.0)
      expect(Absmartly.retry_interval).to eq(1.0)
      expect(Absmartly.max_retries).to eq(3)
    end
  end
end
