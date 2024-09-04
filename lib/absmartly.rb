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
    MUTEX = Thread::Mutex.new

    def configure_client
      yield sdk_config

      sdk_config.validate!
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

    private_constant :MUTEX

    private
      def sdk_config
        MUTEX.synchronize { @sdk_config ||= ABSmartlyConfig.create }
      end

      def sdk
        MUTEX.synchronize { @sdk ||= create }
      end
  end
end
