# frozen_string_literal: true

require "default_http_client_config"
require "context"

RSpec.describe DefaultHttpClientConfig do
  it ".connect_timeout" do
    config = described_class.new
    config.connect_timeout = 123
    expect(config.connect_timeout).to eq(123)
  end

  it ".max_retries" do
    config = described_class.new
    config.max_retries = 123
    expect(config.max_retries).to eq(123)
  end

  it ".retry_interval" do
    config = described_class.new
    config.retry_interval = 123
    expect(config.retry_interval).to eq(123)
  end

  it ".pool_size" do
    config = described_class.new
    expect(config.pool_size).to eq(20)
    config.pool_size = 50
    expect(config.pool_size).to eq(50)
  end

  it ".pool_idle_timeout" do
    config = described_class.new
    expect(config.pool_idle_timeout).to eq(5)
    config.pool_idle_timeout = 10
    expect(config.pool_idle_timeout).to eq(10)
  end
end
