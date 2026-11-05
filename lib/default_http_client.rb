# frozen_string_literal: true

require "faraday"
require "faraday/net_http_persistent"
require "faraday/retry"
require "uri"
require_relative "http_client"

class DefaultHttpClient < HttpClient
  RETRY_METHODS = %i[get put].freeze
  RETRY_IF = lambda do |env, exception|
    RETRY_METHODS.include?(env[:method]) &&
      (env[:method] == :get || !exception.is_a?(Faraday::ConnectionFailed))
  end

  attr_accessor :config, :session

  def self.create(config)
    DefaultHttpClient.new(config)
  end

  def initialize(config)
    @config = config
    @session = Faraday.new("") do |f|
      f.request :retry, **self.class.retry_options(config)
      f.options.timeout = config.connect_timeout
      f.options.open_timeout = config.connection_request_timeout
      f.adapter :net_http_persistent, pool_size: config.pool_size do |http|
        http.idle_timeout = config.pool_idle_timeout
      end
    end
  end

  # Timeouts are retried on GET and PUT, as in v1.3.0; a refused connection
  # only on the context fetch (GET). Status retries are opt-in through
  # retry_statuses, since a retried publish may duplicate events.
  def self.retry_options(config)
    {
      max: config.max_retries,
      interval: config.retry_interval,
      interval_randomness: 0.5,
      backoff_factor: 2,
      exceptions: Faraday::Retry::Middleware::DEFAULT_EXCEPTIONS + [Faraday::ConnectionFailed],
      retry_statuses: Array(config.retry_statuses),
      methods: [],
      retry_if: RETRY_IF
    }
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
