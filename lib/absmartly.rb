# frozen_string_literal: true

require_relative "absmartly/version"
require_relative "absmartly/variant_assigner"
require_relative "a_b_smartly"
require_relative "a_b_smartly_config"
require_relative "client"
require_relative "client_config"
require_relative "context_config"

module Absmartly
  @@init_config = nil

  class Error < StandardError
  end

  class << self
    attr_accessor :endpoint, :api_key, :application, :environment

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
        @client_config
      end

      def sdk_config
        @sdk_config = ABSmartlyConfig.create
        @sdk_config.client = Client.create(client_config)
        @sdk_config
      end

      def sdk
        @sdk ||= create
      end
  end
end
