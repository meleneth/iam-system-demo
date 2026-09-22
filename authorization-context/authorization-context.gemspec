# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "authorization-context"
  spec.version = "0.1.0"
  spec.authors = ["IAM System Demo"]
  spec.summary = "Explicit authorization execution scopes for IAM services"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"
  spec.add_dependency "activesupport", ">= 7.1", "< 9"
end
