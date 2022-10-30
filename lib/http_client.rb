# frozen_string_literal: true

class HttpClient
  # @interface method
  def response
    raise NotImplementedError.new("You must implement response method.")
  end
end
