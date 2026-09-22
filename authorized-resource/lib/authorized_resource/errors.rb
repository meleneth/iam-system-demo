# frozen_string_literal: true

module AuthorizedResource
  class Error < StandardError; end
  class PolicyConfigurationError < Error; end
  class UnsupportedOperationError < Error; end
  class ReadOnlyError < Error; end
  class AuthorizationDenied < Error; end
  class AuthorizationTransportError < Error; end
end
