# frozen_string_literal: true

require_relative "http_client"

class DefaultHttpClient < HttpClient
  attr_accessor :reader, :log

  def self.create(config)
    DefaultHttpClient.new(config)
  end

  def initialize(config)
  end

  def parse(context, experiment_name, variant_name, config)
    JSON.parse(config, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
