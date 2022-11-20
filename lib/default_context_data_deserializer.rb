# frozen_string_literal: true

require "json"
require_relative "context_data_deserializer"
require_relative "json/context_data"

class DefaultContextDataDeserializer < ContextDataDeserializer
  attr_accessor :log, :reader

  def deserialize(bytes, offset, length)
    parse = JSON.parse(bytes[offset..length], symbolize_names: true)
    @reader = ContextData.new(parse[:experiments])
  rescue JSON::ParserError
    nil
  end
end
