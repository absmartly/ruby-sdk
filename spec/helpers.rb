# frozen_string_literal: true
require 'digest/md5'
require "arraybuffer"
require 'murmurhash3'

module Helpers
  def hash_unit(value)

    value.is_a?(String) ? value : value.round(0)
    base64 = Digest::MD5.base64digest(value)

    base64 = base64.include?("+") ? base64.gsub!('+','-') : base64
    base64 = base64.include?("/") ? base64.gsub!('/','_') : base64
    murmur3_32_str_hash(base_64_url_no_padding(base64))

  end

  def base_64_url_no_padding(base64)
    padding = true
    while padding == true
      base64[-1] == "=" ? base64 = base64.chop : padding = false
    end

    base64url = base64
  end
  
  #converting string to byte
  def string_to_uint8_array(value)
    n     = value.length
    array = ArrayBuffer.new(value.length)

    k = 0
    (0..n - 1).each do |index|
      c = value[index].ord

      if c < 0x80
        array[k] = c
        k+=1
      elsif c < 0x800
        array[k] = (c >> 6) | 192
        k+=1
        array[k] = (c & 63) | 128
        k+=1
      else
        array[k] = (c >> 12) | 224
        k+=1
        array[k] = ((c >> 6) & 63) | 128
        k+=1
        array[k] = (c & 63) | 128
        k+=1
      end
    end

    array
  end
end
