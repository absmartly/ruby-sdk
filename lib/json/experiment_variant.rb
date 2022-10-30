# frozen_string_literal: true

class ExperimentVariant
  attr_accessor :name, :config

  def initialize(name = nil, config)
    @name = name
    @config = config
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    that = o
    @name == that.name && @config == that.config
  end

  def hash_code
    { name: @name, config: @config }
  end

  def to_s
    "ExperimentVariant{" +
      "name='" + @name + "'" +
      ", config='" + @config + "'" +
      "}"
  end
end
