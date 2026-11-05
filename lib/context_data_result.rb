# frozen_string_literal: true

# The immutable outcome of one context data fetch. Client#context_data returns
# a new one per call, so concurrent fetches on a shared Client can't observe
# each other's in-flight state.
class ContextDataResult
  attr_reader :data_future, :exception, :promise

  def self.failure(exception, promise = nil)
    new(nil, exception, promise)
  end

  def initialize(data_future, exception = nil, promise = nil)
    @data_future = data_future
    @exception = exception
    @promise = promise
    freeze
  end

  def success?
    @exception.nil?
  end

  alias data data_future
end
