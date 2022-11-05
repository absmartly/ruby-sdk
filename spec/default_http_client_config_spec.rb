# frozen_string_literal: true

require "default_http_client_config"
require "context"
require "byebug"

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
end
