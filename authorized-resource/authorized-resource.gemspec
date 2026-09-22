# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = "authorized-resource"
  spec.version = "0.1.0"
  spec.authors = ["IAM System Demo"]
  spec.summary = "Capability-enforced and instrumented ActiveResource and ActiveModel operations"
  spec.files = Dir["lib/**/*.rb", "README.md"]
  spec.require_paths = ["lib"]
  spec.required_ruby_version = ">= 3.2"
  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  spec.add_dependency "authorization-context", "~> 0.1"
  spec.add_dependency "opentelemetry-api", ">= 1.4", "< 2"
end
