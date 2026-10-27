# frozen_string_literal: true

class ScheduledThreadPoolExecutor
  def initialize(timer = 1)
    @timer = timer
  end

  def execute(&block)
    block.call if block
  end

  def shutdown
  end
end
