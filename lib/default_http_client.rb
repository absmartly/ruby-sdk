# frozen_string_literal: true

require "faraday"
require "uri"
require_relative "http_client"

class DefaultHttpClient < HttpClient
  attr_accessor :config, :session

  def self.create(config)
    DefaultHttpClient.new(config)
  end

  def initialize(config)
    @config = config
    @session = Faraday.new("") do |f|
      f.request :retry,
                max: config.max_retries,
                interval: config.retry_interval,
                interval_randomness: 0.5,
                backoff_factor: 2
      f.options.timeout = config.connect_timeout
      f.options.open_timeout = config.connection_request_timeout
    end
  end

  # def context_data
  # end

  def get(url, query, headers)
    @session.get(url, query, headers)
  end

  def put(url, query, headers, body)
    @session.put(add_tracking(url, query), body, headers)
  end

  def post(url, query, headers, body)
    @session.post(add_tracking(url, query), body, headers)
  end

  def close
    @session.close
  end

  def self.default_response(status_code, status_message, content_type, content)
    env = Faraday::Env.from(status: status_code, body: content || status_message,
                      response_headers: { "Content-Type" => content_type })
    Faraday::Response.new(env)
  end

  private
    def add_tracking(url, params)
      parsed = URI.parse(url)
      query = parsed.query ? CGI.parse(parsed.query) : {}
      query = query.merge(params) if params && params.is_a?(Hash)
      parsed.query = URI.encode_www_form(query)
      str = parsed.to_s
      str[-1] == "?" ? str.chop : str
    end
end
