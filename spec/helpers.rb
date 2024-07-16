# frozen_string_literal: true

require "json"

module Helpers
  def resource(file_name)
    File.read(File.join("spec", "fixtures", "resources", file_name))
  end

  def failed_future(e)
  end
end
