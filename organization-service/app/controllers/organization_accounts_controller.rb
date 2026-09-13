class OrganizationAccountsController < ApplicationController
  before_action :set_organization_account, only: %i[ show update destroy ]
  before_action :require_filters, only: [ :index ]

  def require_filters
    if params.slice(*OrganizationAccount.allowed_filters).blank?
      render json: { error: "Filter required" }, status: 400
    end
  end

  # GET /organization_accounts
  def index
    filters = params.slice(*OrganizationAccount.allowed_filters).permit!
    raise BadFilterError unless filters.present?

    pad_user_id = request.headers["HTTP_PAD_USER_ID"]
    raise AuthorizationDenied, "no pad-user-id header sent" unless pad_user_id

    results = OrganizationAccount.where(filters).to_a
    results.each { |relationship| authorize_relationship_read!(pad_user_id, relationship) }

    render json: results
  end

  def for_account
    filters = params.slice(:account_id).permit!

    pad_user_id = request.headers["HTTP_PAD_USER_ID"]
    raise AuthorizationDenied, "no pad-user-id header sent" unless pad_user_id

    authorize_account_read!(pad_user_id, filters[:account_id]) if filters[:account_id]

    results = organization_payloads_for_account_ids([filters[:account_id]])
    render json: results.fetch(filters[:account_id].to_s)
  end

  def for_accounts
    account_ids = begin
      ids = params.permit(account_ids: [])[:account_ids]
      raise ActionController::BadRequest, "account_ids must be an array" unless ids.is_a?(Array)
      raise ActionController::BadRequest, "account_ids must not be empty" if ids.empty?
      ids
    end

    Instrumentation.trace("organization_accounts.authorize", attributes: { "scope.count" => account_ids.size }) do
      pad_user_id = request.headers["HTTP_PAD_USER_ID"]
      raise AuthorizationDenied, "no pad-user-id header sent" unless pad_user_id
      authorize_account_read!(pad_user_id, account_ids)
    end

    payload = begin
      compressed_organization_account_ids_for_account_ids(account_ids)
    end
    render json: payload
  end

  # GET /organization_accounts/1
  def show
    actor = request.headers["HTTP_PAD_USER_ID"]
    raise AuthorizationDenied if actor.blank?
    authorize_relationship_read!(actor, @organization_account)
    render json: @organization_account
  end

  # POST /organization_accounts
  def create
    @organization_account = OrganizationAccount.new(organization_account_params)

    if @organization_account.save
      render json: @organization_account, status: :created, location: @organization_account
    else
      render json: @organization_account.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /organization_accounts/1
  def update
    if @organization_account.update(organization_account_params)
      render json: @organization_account
    else
      render json: @organization_account.errors, status: :unprocessable_entity
    end
  end

  # DELETE /organization_accounts/1
  def destroy
    @organization_account.destroy!
  end

  private

  def authorize_relationship_read!(actor, relationship)
    return if actor == "IAM_SYSTEM"

    # Reuse organization decisions within this response, even for large listings.
    @relationship_organization_reads ||= {}
    organization_id = relationship.organization_id
    organization_allowed = @relationship_organization_reads.fetch(organization_id) do
      @relationship_organization_reads[organization_id] = organization_accounts_read?(actor, organization_id)
    end
    return if organization_allowed || User.user_can(actor, "Account", "account.read", relationship.account_id)

    raise AuthorizationDenied
  end

  def authorize_account_read!(pad_user_id, account_ids)
    return if pad_user_id == "IAM_SYSTEM"

    unless User.user_can(pad_user_id, "Account", "account.read", account_ids)
      raise AuthorizationDenied, "no authorization for #{pad_user_id} account.read #{account_ids}"
    end
  end

  def organization_accounts_read?(pad_user_id, organization_id)
    Array(organization_id).all? do |id|
      User.user_can(pad_user_id, "Organization", "organization.read.accounts", id) ||
        User.user_can(pad_user_id, "Organization", "organization.accounts.read", id)
    end
  end

  def organization_payloads_for_account_ids(account_ids)
    ids = Array(account_ids).map(&:to_s)
    compressed = compressed_organization_account_ids_for_account_ids(ids)
    actor = request.headers["HTTP_PAD_USER_ID"]
    unless actor == "IAM_SYSTEM" || User.user_can(actor, "Organization", "organization.read", compressed.fetch(:organizations).keys)
      raise AuthorizationDenied
    end
    organizations = Organization.where(id: compressed.fetch(:organizations).keys).index_by { |organization| organization.id.to_s }

    ids.to_h do |account_id|
      organization_id = compressed.fetch(:account_to_organization).fetch(account_id)
      [
        account_id,
        {
          organization: organizations.fetch(organization_id),
          account_ids: compressed.fetch(:organizations).fetch(organization_id)
        }
      ]
    end
  end

  def compressed_organization_account_ids_for_account_ids(account_ids)
    ids = Array(account_ids).map(&:to_s)
    org_accounts, org_account_by_account_id = begin
      rows = OrganizationAccount.where(account_id: ids).to_a
      [rows, rows.index_by { |org_account| org_account.account_id.to_s }]
    end
    missing_ids = ids - org_account_by_account_id.keys
    raise ActiveRecord::RecordNotFound, "No organization accounts for account_ids #{missing_ids}" if missing_ids.any?

    organization_ids = org_accounts.map { |org_account| org_account.organization_id.to_s }.uniq
    actor = request.headers["HTTP_PAD_USER_ID"]
    raise AuthorizationDenied if actor.blank?
    unless actor == "IAM_SYSTEM" || organization_accounts_read?(actor, organization_ids)
      raise AuthorizationDenied
    end
    account_ids_by_organization_id = cached_account_ids_by_organization_id(organization_ids)

    account_to_organization = ids.to_h do |account_id|
      org_account = org_account_by_account_id.fetch(account_id)
      [account_id, org_account.organization_id.to_s]
    end

    {
      organizations: account_ids_by_organization_id,
      account_to_organization: account_to_organization
    }
  end

  def cached_account_ids_by_organization_id(organization_ids)
    Instrumentation.trace("organization_accounts.cache.fetch", attributes: { "scope.count" => organization_ids.size }) do
      cache_keys = organization_ids.map { |organization_id| account_ids_cache_key(organization_id) }
      cached_values = Instrumentation.trace("organization_accounts.cache.lookup", attributes: { "scope.count" => organization_ids.size }) do
        ORGANIZATION_CACHE.pipelined do |pipe|
          cache_keys.each { |cache_key| pipe.get(cache_key) }
        end
      end

      by_organization_id = {}
      misses = []

      if cache_disabled?
        OpenTelemetry::Trace.current_span.add_event("Redis cache disabled; treating #{organization_ids.size} organization account-id lists as misses")
      end

      organization_ids.each_with_index do |organization_id, index|
        cached = cached_values[index]
        if cached
          by_organization_id[organization_id] = JSON.parse(cached)
        else
          misses << organization_id
        end
      end
      IamDemo::CacheMetrics.record(
        cache: "account_ids_by_organization",
        outcome: "hit",
        count: organization_ids.size - misses.size,
        redis_enabled: !cache_disabled?
      )
      IamDemo::CacheMetrics.record(
        cache: "account_ids_by_organization",
        outcome: "miss",
        count: misses.size,
        redis_enabled: !cache_disabled?
      )

      if misses.any?
        Instrumentation.trace("organization_accounts.cache.miss.load") do
          OrganizationAccount.where(organization_id: misses).group_by { |org_account| org_account.organization_id.to_s }.each do |organization_id, rows|
            by_organization_id[organization_id] = rows.map(&:account_id)
          end
        end

        unless cache_disabled?
          ORGANIZATION_CACHE.pipelined do |pipe|
            misses.each do |organization_id|
              pipe.set(account_ids_cache_key(organization_id), by_organization_id.fetch(organization_id).to_json, ex: 300)
            end
          end
        else
          OpenTelemetry::Trace.current_span.add_event("Redis cache disabled; skipped writing #{misses.size} organization account-id lists")
        end
      end

      by_organization_id
    end
  end

  def cache_disabled?
    ORGANIZATION_CACHE.respond_to?(:redis_enabled?) && !ORGANIZATION_CACHE.redis_enabled?
  end

  def account_ids_cache_key(organization_id)
    "account_ids_by_organization:#{organization_id}"
  end

    # Use callbacks to share common setup or constraints between actions.
    def set_organization_account
      @organization_account = OrganizationAccount.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def organization_account_params
      params.require(:organization_account).permit(:organization_id, :account_id)
    end
end
