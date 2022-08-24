# frozen_string_literal: true

require_relative "absmartly/version"
require_relative "absmartly/variant_assigner"
require_relative "absmartly/md5"
require_relative "absmartly/jsonexpr/jsonexpr"

module Absmartly
  class Error < StandardError
  end
end
