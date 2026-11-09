# frozen_string_literal: true

# Raised/returned for a routine publish rejection from the ABSmartly collector
# (for example an HTTP 5xx). It descends from StandardError so applications can
# recover from an operational failure with an ordinary `rescue => e` /
# `rescue StandardError` around close, finalize or publish, rather than being
# forced to rescue Ruby's base Exception.
class PublishError < StandardError
end
