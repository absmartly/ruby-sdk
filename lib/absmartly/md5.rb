# frozen_string_literal: true

require "arraybuffer"

module Absmartly
  class Md5
    def self.cmn (q, a, b, x, s, t)
      a = a + q + (x >> 0) + t # TODO >>>
      ((a << s) | (a >> (32 - s))) + b # TODO >>>
    end

    def self.ff(a, b, c, d, x, s, t)
      cmn((b & c) | (~b & d), a, b, x, s, t)
    end

    def self.gg(a, b, c, d, x, s, t)
      cmn((b & d) | (c & ~d), a, b, x, s, t)
    end

    def self.hh(a, b, c, d, x, s, t)
      cmn(b ^ c ^ d, a, b, x, s, t)
    end

    def self.ii(a, b, c, d, x, s, t)
      cmn(c ^ (b | ~d), a, b, x, s, t)
    end

    def self.md5_cycle(x, k)
      a = x[0]
      b = x[1]
      c = x[2]
      d = x[3]

      a = ff(a, b, c, d, k[0], 7, -680876936)
      d = ff(d, a, b, c, k[1], 12, -389564586)
      c = ff(c, d, a, b, k[2], 17, 606105819)
      b = ff(b, c, d, a, k[3], 22, -1044525330)
      a = ff(a, b, c, d, k[4], 7, -176418897)
      d = ff(d, a, b, c, k[5], 12, 1200080426)
      c = ff(c, d, a, b, k[6], 17, -1473231341)
      b = ff(b, c, d, a, k[7], 22, -45705983)
      a = ff(a, b, c, d, k[8], 7, 1770035416)
      d = ff(d, a, b, c, k[9], 12, -1958414417)
      c = ff(c, d, a, b, k[10], 17, -42063)
      b = ff(b, c, d, a, k[11], 22, -1990404162)
      a = ff(a, b, c, d, k[12], 7, 1804603682)
      d = ff(d, a, b, c, k[13], 12, -40341101)
      c = ff(c, d, a, b, k[14], 17, -1502002290)
      b = ff(b, c, d, a, k[15], 22, 1236535329)

      a = gg(a, b, c, d, k[1], 5, -165796510)
      d = gg(d, a, b, c, k[6], 9, -1069501632)
      c = gg(c, d, a, b, k[11], 14, 643717713)
      b = gg(b, c, d, a, k[0], 20, -373897302)
      a = gg(a, b, c, d, k[5], 5, -701558691)
      d = gg(d, a, b, c, k[10], 9, 38016083)
      c = gg(c, d, a, b, k[15], 14, -660478335)
      b = gg(b, c, d, a, k[4], 20, -405537848)
      a = gg(a, b, c, d, k[9], 5, 568446438)
      d = gg(d, a, b, c, k[14], 9, -1019803690)
      c = gg(c, d, a, b, k[3], 14, -187363961)
      b = gg(b, c, d, a, k[8], 20, 1163531501)
      a = gg(a, b, c, d, k[13], 5, -1444681467)
      d = gg(d, a, b, c, k[2], 9, -51403784)
      c = gg(c, d, a, b, k[7], 14, 1735328473)
      b = gg(b, c, d, a, k[12], 20, -1926607734)

      a = hh(a, b, c, d, k[5], 4, -378558)
      d = hh(d, a, b, c, k[8], 11, -2022574463)
      c = hh(c, d, a, b, k[11], 16, 1839030562)
      b = hh(b, c, d, a, k[14], 23, -35309556)
      a = hh(a, b, c, d, k[1], 4, -1530992060)
      d = hh(d, a, b, c, k[4], 11, 1272893353)
      c = hh(c, d, a, b, k[7], 16, -155497632)
      b = hh(b, c, d, a, k[10], 23, -1094730640)
      a = hh(a, b, c, d, k[13], 4, 681279174)
      d = hh(d, a, b, c, k[0], 11, -358537222)
      c = hh(c, d, a, b, k[3], 16, -722521979)
      b = hh(b, c, d, a, k[6], 23, 76029189)
      a = hh(a, b, c, d, k[9], 4, -640364487)
      d = hh(d, a, b, c, k[12], 11, -421815835)
      c = hh(c, d, a, b, k[15], 16, 530742520)
      b = hh(b, c, d, a, k[2], 23, -995338651)

      a = ii(a, b, c, d, k[0], 6, -198630844)
      d = ii(d, a, b, c, k[7], 10, 1126891415)
      c = ii(c, d, a, b, k[14], 15, -1416354905)
      b = ii(b, c, d, a, k[5], 21, -57434055)
      a = ii(a, b, c, d, k[12], 6, 1700485571)
      d = ii(d, a, b, c, k[3], 10, -1894986606)
      c = ii(c, d, a, b, k[10], 15, -1051523)
      b = ii(b, c, d, a, k[1], 21, -2054922799)
      a = ii(a, b, c, d, k[8], 6, 1873313359)
      d = ii(d, a, b, c, k[15], 10, -30611744)
      c = ii(c, d, a, b, k[6], 15, -1560198380)
      b = ii(b, c, d, a, k[13], 21, 1309151649)
      a = ii(a, b, c, d, k[4], 6, -145523070)
      d = ii(d, a, b, c, k[11], 10, -1120210379)
      c = ii(c, d, a, b, k[2], 15, 718787259)
      b = ii(b, c, d, a, k[9], 21, -343485551)

      x[0] = (a + x[0]) >> 0 # TODO >>>
      x[1] = (b + x[1]) >> 0 # TODO >>>
      x[2] = (c + x[2]) >> 0 # TODO >>>
      x[3] = (d + x[3]) >> 0 # TODO >>>
    end

    def self.process(new_bytes_buffer)
      key = DataView.new(new_bytes_buffer, 0, new_bytes_buffer.length)

      l     = new_bytes_buffer.length
      n     = l & ~63
      i     = 0
      block = ArrayBuffer.new(16)
      state = ArrayBuffer.new(4)

      [1732584193, -271733879, -1732584194, 271733878].each_with_index do |el, index|
        bytes        = el.to_s.bytes
        state[index] = [el].pack("L").unpack("L").first
      end


      (0...n).step(64).each do |val|
        (0...16).each do |w|
          block[w] = key.getU32(val + (w << 2))
        end

        md5_cycle(state, block)

        i += 64
      end

      w = 0
      m = l & ~3

      (i...m).step(4).each do |val|
        block[w] = key.getU32(val)
        w        += 1
      end

      p = l & 3

      case p
      when 3
        block[w] = 0x80000000 | key.getU8(i) | (key.getU8(i + 1) << 8) | (key.getU8(i + 2) << 16)
        w        += 1
      when 2
        block[w] = 0x800000 | key.getUint8(i) | (key.getUint8(i + 1) << 8)
        w        += 1

      when 1
        block[w] = 0x8000 | key.getUint8(i)
        w        += 1

      else
        block[w] = 0x80
        w        += 1

      end

      if w > 14
        (w...16).each do |v|
          block[v] = 0
        end

        md5_cycle(state, block)
        w = 0
      end

      (w...16).each do |v|
        block[v] = 0
      end

      block[14] = l << 3
      md5_cycle(state, block)

      state
    end
  end
end
