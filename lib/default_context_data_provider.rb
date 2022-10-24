# frozen_string_literal: true

require_relative "context_data_provider"

class DefaultContextDataProvider < ContextDataProvider
  attr_accessor :client

  def initialize(client)
    @client = client
  end

  def context_data
    @client.context_data
  end
end
