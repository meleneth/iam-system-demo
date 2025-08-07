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
    raise "no pad-user-id header sent" unless pad_user_id

    if pad_user_id != "IAM_SYSTEM"
      if filters[:organization_id]
        unless User.user_can(pad_user_id, "Organization", "organization.accounts.read",  filters[:organization_id])
          raise "no authorization for #{pad_user_id} organization.accounts.read #{filters[:organization_id]}"
        end
      end
      if filters[:account_id]
        unless User.user_can(pad_user_id, "Account", "account.read",  filters[:account_id])
          raise "no authorization for #{pad_user_id} account.read #{filters[:account_id]}"
        end
      end
    end
    results = OrganizationAccount.where(*filters)

    render json: results
  end

  # GET /organization_accounts/1
  def show
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
    # Use callbacks to share common setup or constraints between actions.
    def set_organization_account
      @organization_account = OrganizationAccount.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def organization_account_params
      params.require(:organization_account).permit(:organization_id, :account_id)
    end
end
