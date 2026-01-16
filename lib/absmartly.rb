# frozen_string_literal: true

require_relative "absmartly/version"
require_relative "a_b_smartly"
require_relative "a_b_smartly_config"
require_relative "client"
require_relative "client_config"
require_relative "context_config"

module Absmartly
  class Error < StandardError
  end

  class << self
    attr_accessor :endpoint, :api_key, :application, :environment,
                  :connect_timeout, :connection_request_timeout, :retry_interval, :max_retries,
                  :event_logger

    def configure_client
      yield self
    end

    def create
      ABSmartly.create(sdk_config)
    end

    def create_context_config
      ContextConfig.create
    end

    def create_context(context_config)
      sdk.create_context(context_config)
    end

    def create_context_with(context_config, data)
      sdk.create_context_with(context_config, data)
    end

    def context_data
      sdk.context_data
    end

    private
      def client_config
        @client_config = ClientConfig.create
        @client_config.endpoint = @endpoint
        @client_config.api_key = @api_key
        @client_config.application = @application
        @client_config.environment = @environment
        @client_config.connect_timeout = @connect_timeout
        @client_config.connection_request_timeout = @connection_request_timeout
        @client_config.retry_interval = @retry_interval
        @client_config.max_retries = @max_retries
        @client_config
      end

      def sdk_config
        @sdk_config = ABSmartlyConfig.create
        @sdk_config.client = Client.create(client_config)
        @sdk_config.context_event_logger = @event_logger
        @sdk_config
      end

      def sdk
        @sdk ||= create
      end
  end
end
