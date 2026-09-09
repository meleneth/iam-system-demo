# frozen_string_literal: true
require "json"
require "open3"

module StackPorts
  def self.check!(configs)
    bindings = []
    configs.each do |stack, config|
      config.fetch("services").each do |service, settings|
        settings.fetch("ports", []).each do |port|
          published = port["published"]
          raise "#{stack}/#{service}: published port must be explicit" unless published.to_s.match?(/\A[1-9][0-9]*\z/)
          binding = { port: published.to_i, protocol: port.fetch("protocol", "tcp"),
            address: port.fetch("host_ip", "0.0.0.0"), owner: "#{stack}/#{service}" }
          conflict = bindings.find { |other|
            other[:port] == binding[:port] && other[:protocol] == binding[:protocol] &&
              (other[:address] == binding[:address] || [other[:address], binding[:address]].any? { |ip| %w[0.0.0.0 ::].include?(ip) })
          }
          raise "Port conflict: #{conflict[:owner]} and #{binding[:owner]} on #{published}/#{binding[:protocol]}" if conflict
          bindings << binding
        end
      end
    end
    bindings.size
  end
end

if $PROGRAM_NAME == __FILE__
  configs = %w[test dev prod].to_h do |stack|
    output, status = Open3.capture2("./dc_#{stack}", "config", "--format", "json")
    raise "Cannot resolve #{stack} configuration" unless status.success?
    [stack, JSON.parse(output)]
  end
  puts "Checked #{StackPorts.check!(configs)} non-conflicting port bindings across test, dev and prod."
end
