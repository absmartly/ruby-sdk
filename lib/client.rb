# frozen_string_literal: true

require "forwardable"
require_relative "default_http_client"
require_relative "default_http_client_config"
require_relative "default_context_data_deserializer"
require_relative "default_context_event_serializer"

class Client
  extend Forwardable

  attr_accessor :http_client
  attr_reader :config, :data_future, :promise, :exception

  def_delegators :@config, :url, :query, :headers, :deserializer, :serializer
  def_delegator :@http_client, :close
  def_delegator :@promise, :success?

  def self.create(config = nil, http_client = nil)
    new(config, http_client)
  end

  def initialize(config = nil, http_client = nil)
    @config = config || ClientConfig.new
    @config.validate!

    @http_client = http_client || DefaultHttpClient.create(@config.http_client_config)
  end

  def context_data
    @promise = http_client.get(config.url, config.query, config.headers)
    unless @promise.success?
      @exception = Exception.new(@promise.body)
      return self
    end

    content = (@promise.body || {}).to_s
    @data_future = deserializer.deserialize(content, 0, content.size)
    self
  end

  def publish(event)
    content = serializer.serialize(event)
    response = http_client.put(config.url, nil, config.headers, content)
    return Exception.new(response.body) unless response.success?

    response
  end
end
