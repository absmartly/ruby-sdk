# frozen_string_literal: true

require "digest"

class Hashing
  def self.hash_unit(str)
    Digest::MD5.base64digest(str.to_s).gsub("==", "").gsub("+", "-").gsub("/", "_")
  end
end
