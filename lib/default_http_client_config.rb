# frozen_string_literal: true

class DefaultHttpClientConfig
  attr_accessor :connect_timeout,
                :connection_request_timeout,
                :retry_interval,
                :max_retries,
                :pool_size,
                :pool_idle_timeout

  def self.create
    DefaultHttpClientConfig.new
  end

  def initialize
    @connect_timeout = 3.0
    @connection_request_timeout = 3.0
    @retry_interval = 0.5
    @max_retries = 5
    @pool_size = 20
    @pool_idle_timeout = 5
  end
end
