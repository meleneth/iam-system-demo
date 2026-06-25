# frozen_string_literal: true

class MspReflectedGrantLoading < StandardError
  attr_reader :status

  def initialize(status)
    @status = status.symbolize_keys
    super("MSP reflected user-management grants are loading")
  end
end
