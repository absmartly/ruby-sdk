# frozen_string_literal: true

require "arraybuffer"

module Helpers
  def hash_unit(value)
    Absmartly::Md5.process(string_to_uint8_array(value))
    # base_64_url_no_padding(Absmartly::Md5.process(string_to_uint8_array(value)))
  end

  def base_64_url_no_padding(value)
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
