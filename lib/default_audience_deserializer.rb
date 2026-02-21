# frozen_string_literal: true

require_relative "audience_deserializer"

class DefaultAudienceDeserializer < AudienceDeserializer
  attr_accessor :log, :reader

  def deserialize(bytes, offset, length)
    JSON.parse(bytes[offset..length], symbolize_names: true)
  rescue JSON::ParserError => e
    warn("Failed to deserialize audience data: #{e.message}")
    nil
  rescue StandardError => e
    warn("Unexpected error deserializing audience data: #{e.class} - #{e.message}")
    nil
  end
end
