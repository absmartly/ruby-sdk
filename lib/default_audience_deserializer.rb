# frozen_string_literal: true

require_relative "audience_deserializer"

class DefaultAudienceDeserializer < AudienceDeserializer
  attr_accessor :log, :reader

  def deserialize(bytes, offset, length)
    @reader.readValue(bytes, offset, length)
  end
end
