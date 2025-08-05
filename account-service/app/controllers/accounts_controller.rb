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
      user = User.find(pad_user_id)
      raise "no authorization for #{pad_user_id} account.read #{account_id}" unless user.can("Account", "account.read",  account_id)
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

      if cached = ACCOUNT_CACHE.get(cache_key)
        OpenTelemetry::Trace.current_span.add_event("Fetching cached account_with_parents SUCCESS!")
        return JSON.parse(cached)
      end

      OpenTelemetry::Trace.current_span.add_event("Fetching account_with_parents failed, doing it the slow way")

      account = Account.find(account_id)
      org_accounts = false
      org_key_set = ""
      OrganizationAccount.with_headers('pad-user-id' => 'IAM_SYSTEM') do
        org_account = OrganizationAccount.find(:first, params: { account_id: account.id })
        org_accounts = OrganizationAccount.find(:all, params: { organization_id: org_account.organization_id })
        org_key_set = "dev:org_cachekeys:#{org_account.organization_id}"
      end
      seed_ids = org_accounts.map(&:account_id)

      accounts = Arel::Table.new(:accounts)

      base_query = accounts
        .project(
          accounts[:id],
          accounts[:parent_account_id],
          accounts[:name],
          Arel.sql("0 AS level")
        )
        .where(accounts[:id].eq(account.id))

      # Interpolate safe UUID strings
      seed_id_list = seed_ids.map { |id| ActiveRecord::Base.connection.quote(id) }.join(", ")

      recursive_sql = <<~SQL
        SELECT a.id, a.parent_account_id, a.name, t.level + 1
        FROM accounts a
        INNER JOIN account_ancestry t ON t.parent_account_id = a.id
        WHERE a.id IN (#{seed_id_list})
      SQL

      final_sql = <<~SQL
        WITH RECURSIVE account_ancestry(id, parent_account_id, name, level) AS (
          #{base_query.to_sql}
          UNION ALL
          #{recursive_sql}
        )
        SELECT *
        FROM account_ancestry
        WHERE id != #{ActiveRecord::Base.connection.quote(account.id)}
        ORDER BY level DESC
      SQL

      results =  ActiveRecord::Base.connection.execute(final_sql).to_a
      results << account

      ACCOUNT_CACHE.set(cache_key, results.to_json, ex: 300) # optional TTL
      # Register this cache key for the org so we can later bulk delete
      ACCOUNT_CACHE.sadd(org_key_set, cache_key)
      results
    end
end
