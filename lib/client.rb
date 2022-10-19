# frozen_string_literal: true

class Client
  attr_accessor :url, :query, :headers, :http_client, :executor, :deserializer, :serializer

  def self.create(config, http_client)
  end

  def initialize(config = nil, http_client = nil)
  end

  def context_data
  end

  def publish(event)
  end

  def close
  end
end
