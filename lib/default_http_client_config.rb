# frozen_string_literal: true

class DefaultHttpClientConfig
  attr_accessor :connect_timeout,
                :connection_request_timeout,
                :retry_interval,
                :max_retries,
                :pool_size,
                :pool_idle_timeout,
                :retry_statuses,
                :retry_connection_failures

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
    # e.g. [502, 503, 504]
    @retry_statuses = []
    @retry_connection_failures = false
  end
end
