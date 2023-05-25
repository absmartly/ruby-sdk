# frozen_string_literal: true

# $:.push File.expand_path("../lib", __FILE__)
require File.expand_path("lib/absmartly/version", __dir__)
Gem::Specification.new do |spec|
  spec.name = "absmartly-sdk"
  spec.version = Absmartly::VERSION
  spec.authors = ["absmartly"]
  spec.email = ["sdks@absmartly.com"]

  spec.summary = "Absmartly gem"
  spec.description = "Absmartly gem"

  spec.homepage = "https://github.com/absmartly/ruby-sdk"

  spec.license = "MIT"
  spec.required_ruby_version = ">= 2.7.0"
  spec.extra_rdoc_files = ["README.md"]

  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/absmartly/ruby-sdk"
  spec.metadata["changelog_uri"] = "https://github.com/absmartly/ruby-sdk"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  spec.files = Dir.chdir(__dir__) do
    `git ls-files -z`.split("\x0").reject do |f|
      (f == __FILE__) || f.match(%r{\A(?:(?:bin|test|spec|features)/|\.(?:git|travis|circleci)|appveyor)})
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "faraday", "~> 2.0"
  spec.add_dependency "faraday-retry", "~> 2.0"
  spec.add_dependency "murmurhash3", "~> 0.1.7"
  spec.add_dependency "arraybuffer", "~> 0.0.6"

  # For more information and examples about making a new gem, check out our
  # guide at: https://bundler.io/guides/creating_gem.html
end
