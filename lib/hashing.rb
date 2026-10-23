# frozen_string_literal: true

require "digest"

class Hashing
  REPLACEMENT = "�"
  # A UTF-16 surrogate pair written as two 3-byte sequences (CESU-8 / WTF-8).
  ENCODED_SURROGATE_PAIR = /\xED([\xA0-\xAF])([\x80-\xBF])\xED([\xB0-\xBF])([\x80-\xBF])/n.freeze
  # A lone surrogate written as a 3-byte sequence.
  ENCODED_SURROGATE = /\xED[\xA0-\xBF][\x80-\xBF]/n.freeze

  def self.hash_unit(str)
    Digest::MD5.base64digest(to_utf8(str).b).gsub("==", "").gsub("+", "-").gsub("/", "_")
  end

  # Returns the UTF-8 form of the unit's Unicode text. Characters outside the
  # BMP become the standard 4-byte sequence and each lone surrogate becomes
  # U+FFFD, matching the JavaScript SDK's TextEncoder-based encoding. Strings in
  # another encoding (e.g. UTF-16) are transcoded; binary strings are read as
  # UTF-8 bytes.
  def self.to_utf8(value)
    str = value.to_s
    if str.encoding == Encoding::UTF_8 || str.encoding == Encoding::BINARY || str.encoding == Encoding::US_ASCII
      return str if str.encoding == Encoding::UTF_8 && str.valid_encoding?

      bytes = str.b
      bytes = bytes.gsub(ENCODED_SURROGATE_PAIR) do
        high = 0xD800 | ((Regexp.last_match(1).ord & 0x0F) << 6) | (Regexp.last_match(2).ord & 0x3F)
        low = 0xDC00 | ((Regexp.last_match(3).ord & 0x0F) << 6) | (Regexp.last_match(4).ord & 0x3F)
        [0x10000 + ((high - 0xD800) << 10) + (low - 0xDC00)].pack("U").b
      end
      bytes = bytes.gsub(ENCODED_SURROGATE, REPLACEMENT.b)
      bytes.force_encoding(Encoding::UTF_8).scrub(REPLACEMENT)
    else
      str.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
    end
  end
end
