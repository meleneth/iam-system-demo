# frozen_string_literal: true

# Name the existing HTTP span after rendering, using the objects already loaded
# for the response. Never issue a count query or parse the serialized body.
module RequestOperationTracing
  HEADER = 'X-IAM-Trace-Operation'
  RECORDS = {
    'users' => 'user', 'accounts' => 'account', 'organizations' => 'organization',
    'groups' => 'group', 'group_users' => 'group membership',
    'organization_accounts' => 'organization account relationship'
  }.freeze
  READ_ACTIONS = %w[index search show account_with_parents accounts_with_parents].freeze

  def render(*args, **options, &block)
    payload = options[:json]
    payload = args.first[:json] if payload.nil? && args.first.is_a?(Hash)
    super.tap do
      if response.status.between?(200, 299)
        label = response_operation(payload)
        trace_request_operation(label) if label
      elsif controller_path == 'can'
        trace_request_operation(authorization_operation)
      end
    end
  end

  def head(...)
    super.tap do
      trace_request_operation(authorization_operation) if controller_path == 'can'
    end
  end

  private

  def response_operation(payload)
    if RECORDS.key?(controller_path) && READ_ACTIONS.include?(action_name)
      count = loaded_record_count(payload)
      return "Load #{count} #{RECORDS.fetch(controller_path).pluralize(count)}" if count
    end

    case controller_path
    when 'users_counts', 'groups_counts'
      noun = controller_path == 'users_counts' ? 'users' : 'groups'
      "Count #{noun} for #{Array(params[:account_id]).uniq.size} accounts"
    when 'organizations/accounts_count'
      'Count accounts for 1 organization'
    when 'organization_accounts'
      count = action_name == 'for_account' ? 1 : Array(params[:account_ids]).uniq.size
      "Load organization context for #{count} #{'account'.pluralize(count)}"
    when 'internal/auth/contexts'
      key, noun = action_name == 'memberships' ? [:memberships, 'group membership'] : [:groups, 'group']
      count = payload.fetch(key).size
      "Load #{count} #{noun.pluralize(count)} for authorization"
    when 'internal/auth/account_contexts'
      count = payload.fetch(:accounts).size
      noun = action_name == 'providers' ? 'MSP relationship' : 'account authorization context'
      "Load #{count} #{noun.pluralize(count)}"
    when 'internal/msp_managed_organizations'
      count = payload.fetch(:managed_account_ids).size
      "Load #{count} managed account IDs"
    when 'capabilities'
      scope = { 'account' => 'account', 'accounts' => 'account',
                'organization' => 'organization', 'organizations' => 'organization',
                'group' => 'group', 'groups' => 'group' }.fetch(action_name)
      count = payload.is_a?(Hash) ? payload.size : 1
      "Load capabilities for #{count} #{authorization_scope_label(scope, count)}"
    when 'can'
      authorization_operation
    end
  end

  def loaded_record_count(payload)
    return nil if payload.nil?
    if payload.respond_to?(:loaded?)
      return nil unless payload.loaded?
      payload.length
    elsif payload.is_a?(Array)
      payload.flatten.size
    else
      1
    end
  end

  def authorization_operation
    count = Array(params[:scope_id]).map(&:to_s).uniq.size
    "Check #{params[:permission]} for #{count} #{authorization_scope_label(params[:scope_type].to_s.downcase, count)}"
  end

  # Caller intent is display metadata only. Accept a fixed vocabulary and never
  # use it to select an authorization policy or trust level.
  def authorization_scope_label(scope, count)
    noun = scope.pluralize(count)
    return noun unless scope == 'account'

    case request.headers['X-IAM-Authorization-Purpose']
    when 'requested_accounts' then "requested #{noun}"
    when 'returned_hierarchy' then "returned hierarchy #{noun}"
    else noun
    end
  end

  def trace_request_operation(label)
    OpenTelemetry::Trace.current_span.name = label
    # Propagate only the operation label so the caller's HTTP client span can
    # use the same actual returned count without decoding the response again.
    response.set_header(HEADER, label)
  end
end
