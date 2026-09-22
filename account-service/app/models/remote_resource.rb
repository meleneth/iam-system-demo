# frozen_string_literal: true

class RemoteResource < ActiveResource::Base
  include AuthorizationContext::ActiveResourceProtection
end
