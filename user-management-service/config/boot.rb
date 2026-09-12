ENV["BUNDLE_GEMFILE"] ||= File.expand_path("../Gemfile", __dir__)

require "bundler/setup" # Set up gems listed in the Gemfile.
# Load Rack lifecycle hooks before Rails/Puma choose a middleware backend.
require_relative "../lib/rack_phases"
require "bootsnap/setup" # Speed up boot time by caching expensive operations.
