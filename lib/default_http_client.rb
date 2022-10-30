# frozen_string_literal: true

require_relative "http_client"

class DefaultHttpClient < HttpClient
  attr_accessor :reader, :log

  def parse(context, experiment_name, variant_name, config)
    JSON.parse(config, symbolize_names: true)
  rescue JSON::ParserError
    nil
  end
end
