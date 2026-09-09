require "minitest/autorun"
require_relative "../scripts/check_stack_ports"

class StackConfigurationTest < Minitest::Test
  def config(port, protocol = "tcp")
    { "services" => { "cache" => { "ports" => [{ "published" => port, "protocol" => protocol }] } } }
  end

  def test_detects_conflicts_across_stacks
    assert_raises(RuntimeError) { StackPorts.check!({ "dev" => config("11116"), "test" => config("11116") }) }
    assert_equal 2, StackPorts.check!({ "dev" => config("11116"), "prod" => config("11178") })
    assert_equal 2, StackPorts.check!({ "dev" => config("11116"), "prod" => config("11116", "udp") })
  end

end
