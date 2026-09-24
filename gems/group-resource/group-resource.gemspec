# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "group-resource"
  spec.version = "0.1.0"
  spec.authors = ["IAM System Demo"]
  spec.summary = "Authorized remote Group model"
  spec.files = Dir.chdir(__dir__) { Dir["lib/**/*.rb"] }
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"
  spec.add_dependency "authorized-resource", "~> 0.2"
  spec.add_dependency "faraday", ">= 2.0", "< 3"
end
