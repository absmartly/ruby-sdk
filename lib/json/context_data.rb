# frozen_string_literal: true

require_relative "experiment"

class ContextData
  attr_accessor :experiments

  def initialize(experiments = [])
    @experiments = experiments.map do |experiment|
      Experiment.new(experiment)
    end unless experiments.nil?
  end

  def ==(o)
    return true if self.object_id == o.object_id
    return false if o.nil? || self.class != o.class

    @experiments == o.experiments
  end

  def hash_code
    { name: @name, config: @config }
  end

  def to_s
    "ContextData{" +
      "experiments='" + @experiments.join +
      "}"
  end
end
