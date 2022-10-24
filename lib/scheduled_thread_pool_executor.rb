# frozen_string_literal: true

require_relative "audience_deserializer"

class ScheduledThreadPoolExecutor < AudienceDeserializer
  attr_accessor :log, :reader

  def initialize(timer = 1)
  end

  def deserialize(bytes, offset, length)
    @reader.read_value(bytes, offset, length)
  end
end
