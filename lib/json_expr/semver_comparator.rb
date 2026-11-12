# frozen_string_literal: true

# Compares versions like the JavaScript SDK's versionCompare: a leading v/V
# and +build metadata are ignored, missing core parts count as "0", numeric
# identifiers compare by value and rank below alphanumeric ones, and a release
# ranks above its pre-releases. Returns nil when either side is not a version.
module SemverComparator
  NUMERIC_IDENTIFIER = /\A\d+\z/.freeze

  module_function

  def compare(evaluator, lhs, rhs)
    lhs_str = evaluator.string_convert(lhs)
    rhs_str = evaluator.string_convert(rhs)
    return nil if lhs_str.nil? || rhs_str.nil? || lhs_str.empty? || rhs_str.empty?

    l = parse(lhs_str)
    r = parse(rhs_str)
    return nil if l.nil? || r.nil?

    [l[:parts].size, r[:parts].size].max.times do |i|
      result = compare_identifiers(l[:parts][i] || "0", r[:parts][i] || "0")
      return result unless result.zero?
    end

    return 0 if l[:pre_release].empty? && r[:pre_release].empty?
    return 1 if l[:pre_release].empty?
    return -1 if r[:pre_release].empty?

    l_pre = l[:pre_release].split(".", -1)
    r_pre = r[:pre_release].split(".", -1)
    [l_pre.size, r_pre.size].max.times do |i|
      return -1 if i >= l_pre.size
      return 1 if i >= r_pre.size

      result = compare_identifiers(l_pre[i], r_pre[i])
      return result unless result.zero?
    end
    0
  end

  def parse(version)
    v = version
    v = v[1..] if v.start_with?("v", "V")
    plus = v.index("+")
    v = v[0, plus] unless plus.nil?
    return nil if v.empty?

    core, *pre_release = v.split("-", -1)
    return nil if core.nil? || core.empty?

    { parts: core.split(".", -1), pre_release: pre_release.join("-") }
  end

  def compare_identifiers(a, b)
    a_num = a.match?(NUMERIC_IDENTIFIER)
    b_num = b.match?(NUMERIC_IDENTIFIER)

    if a_num && b_num
      a_norm = strip_leading_zeros(a)
      b_norm = strip_leading_zeros(b)
      return a_norm.size <=> b_norm.size unless a_norm.size == b_norm.size

      return a_norm <=> b_norm
    end
    return -1 if a_num
    return 1 if b_num

    a <=> b
  end

  def strip_leading_zeros(s)
    stripped = s.sub(/\A0+/, "")
    stripped.empty? ? "0" : stripped
  end
end
