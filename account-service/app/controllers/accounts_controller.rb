class AccountsController < ApplicationController
  before_action :set_account, only: %i[ show update destroy ]

  # GET /accounts
  def index
    filters = params.slice(*Account.allowed_filters).permit!
    raise BadFilterError unless filters.present?
    results = Account.where(*filters)

    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    if pad_user_id == "IAM_SYSTEM"
      OpenTelemetry::Trace.current_span.add_event("Skipping auth for system user")
    else
      OpenTelemetry::Trace.current_span.add_event("Checking auth for user #{pad_user_id}")
      account_ids = results.map(&:id)
      raise "no authorization for #{pad_user_id} account.read #{account_ids}" unless User.user_can(pad_user_id, "Account", "account.read",  account_ids)
    end

    render json: results
  end

  # GET /with_parent_accounts/1
  def account_with_parents
    account_id = params.permit(:account_id)[:account_id]
    results = fetch_account_with_parents(account_id)

    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    if pad_user_id != "IAM_SYSTEM"
      raise "no authorization for #{pad_user_id} account.read #{account_id}" unless User.user_can(pad_user_id, "Account", "account.read",  account_id)
    end

    render json: results
  end

  # GET /with_parent_accounts
  def accounts_with_parents
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    raise "Access denied to non system user" unless pad_user_id == "IAM_SYSTEM"

    account_ids = params.permit(account_ids: [])[:account_ids]
    raise ActionController::BadRequest, "account_ids must be an array" unless account_ids.is_a?(Array)
    results = account_ids.map { |id| fetch_account_with_parents(id) }
    render json: results
  end

  # GET /accounts/1
  def show
    pad_user_id = request.headers['HTTP_PAD_USER_ID']
    raise "Must pass a pad-user-id header" unless pad_user_id
    if pad_user_id == "IAM_SYSTEM"
      OpenTelemetry::Trace.current_span.add_event("Skipping auth for system user")
    else
      OpenTelemetry::Trace.current_span.add_event("Checking auth for user #{pad_user_id}")
      raise "no authorization for #{pad_user_id} account.read #{@account.id}" unless User.user_can(pad_user_id, "Account", "account.read",  @account.id)
    end
    render json: @account
  end

  # POST /accounts
  def create
    @account = Account.new(account_params)

    if @account.save
      render json: @account, status: :created, location: @account
    else
      render json: @account.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /accounts/1
  def update
    if @account.update(account_params)
      render json: @account
    else
      render json: @account.errors, status: :unprocessable_entity
    end
  end

  # DELETE /accounts/1
  def destroy
    @account.destroy!
  end

  private

  # Use callbacks to share common setup or constraints between actions.
  def set_account
    @account = Account.find(params.expect(:id))
  end

  # Only allow a list of trusted parameters through.
  def account_params
    params.permit(:parent_account_id)
  end

  def fetch_account_with_parents(account_id)
    cache_key = "account_with_parents:#{account_id}"

    if (cached = ACCOUNT_CACHE.get(cache_key))
      OpenTelemetry::Trace.current_span.add_event("Fetching cached account_with_parents SUCCESS!")
      return JSON.parse(cached)
    end

    OpenTelemetry::Trace.current_span.add_event("Fetching account_with_parents failed, doing it the slow way")

    account = Account.find(account_id)

    org_key_set = ""
    seed_ids = []
    OrganizationAccount.with_headers('pad-user-id' => 'IAM_SYSTEM') do
      response     = OrganizationAccount.account_ids_for_organization_by_account_id(account.id)
      organization = response[:organization]
      seed_ids     = response[:account_ids]
      org_key_set  = "org_cachekeys:#{organization.id}"
    end

    # CTE with bind params: $1::uuid for root account, $2::uuid[] for seed ids
    sql = <<~SQL
      WITH RECURSIVE account_ancestry(id, parent_account_id, name, level) AS (
        SELECT a.id, a.parent_account_id, a.name, 0 AS level
        FROM accounts a
        WHERE a.id = $1::uuid

        UNION ALL

        SELECT a.id, a.parent_account_id, a.name, t.level + 1
        FROM accounts a
        INNER JOIN account_ancestry t ON t.parent_account_id = a.id
        WHERE a.id = ANY($2::uuid[])
      )
      SELECT *
      FROM account_ancestry
      WHERE id <> $1::uuid
      ORDER BY level DESC
    SQL

    # ---- Rails type-safe binds ----
    # Rails 7/8: ActiveRecord::Type.lookup works for PG + arrays.
    uuid_type       = ActiveRecord::Type.lookup(:uuid)
    uuid_array_type = ActiveRecord::Type.lookup(:uuid, array: true)

    binds = [
      ActiveRecord::Relation::QueryAttribute.new("account_id", account.id, uuid_type),
      ActiveRecord::Relation::QueryAttribute.new("seed_ids",   seed_ids,   uuid_array_type)
    ]

    OpenTelemetry::Trace.current_span.add_event("AccountWithParentsCTE")

    results = ActiveRecord::Base.connection.exec_query(sql, "AccountWithParentsCTE", binds).to_a

    # include the root account (to match your prior behavior)
    results << account

    ACCOUNT_CACHE.set(cache_key, results.to_json, ex: 300)
    ACCOUNT_CACHE.sadd(org_key_set, cache_key)

    results
  end
end
