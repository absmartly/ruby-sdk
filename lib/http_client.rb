# frozen_string_literal: true

class HttpClient
  # @interface method
  def response
    raise NotImplementedError.new("You must implement response method.")
  end

  def get(url, query, headers)
    raise NotImplementedError.new("You must implement get method.")
  end

  def post(url, query, headers, body)
    raise NotImplementedError.new("You must implement post method.")
  end

  def put(url, query, headers, body)
    raise NotImplementedError.new("You must implement put method.")
  end
end
