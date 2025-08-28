# config/initializers/fiber_headers.rb
module FiberHeaderHelpers
  STORE_KEY = :account_headers

  def with_headers(temp_headers)
    base = (ActiveSupport::IsolatedExecutionState[STORE_KEY] ||= {})
    old  = base.dup
    base.merge!(temp_headers)
    yield
  ensure
    ActiveSupport::IsolatedExecutionState[STORE_KEY] = old
  end

  def current_headers
    (headers || {}).merge(ActiveSupport::IsolatedExecutionState[STORE_KEY] || {})
  end
end
