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
