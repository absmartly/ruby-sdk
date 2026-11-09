# frozen_string_literal: true

require_relative "default_context_publisher"

# @deprecated Use DefaultContextPublisher instead.
DefaultContextEventHandler = DefaultContextPublisher
Object.deprecate_constant :DefaultContextEventHandler
