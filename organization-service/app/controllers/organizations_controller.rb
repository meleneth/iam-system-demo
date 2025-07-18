class OrganizationsController < ApplicationController
  before_action :set_organization, only: %i[ show update destroy ]

  # GET /organizations
  def index
    @organizations = Organization.all

    render json: @organizations
  end

  # GET /organizations/1
  def show
    permitted = params.permit(:id)
    organization_id = permitted[:id]
    pad_user_id = request.headers["HTTP_PAD_USER_ID"]
    raise "no pad-user-id header sent" unless pad_user_id
    if pad_user_id != "IAM_SYSTEM"
      user = User.find(pad_user_id)
      unless user.can("Organization", "organization.read",  organization_id)
        raise "no authorization for #{pad_user_id} organization.accounts.read #{organization_id}"
      end
    end
    render json: @organization
  end

  # POST /organizations
  def create
    @organization = Organization.new(organization_params)

    if @organization.save
      render json: @organization, status: :created, location: @organization
    else
      render json: @organization.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /organizations/1
  def update
    if @organization.update(organization_params)
      render json: @organization
    else
      render json: @organization.errors, status: :unprocessable_entity
    end
  end

  # DELETE /organizations/1
  def destroy
    @organization.destroy!
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_organization
      @organization = Organization.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def organization_params
      params.fetch(:organization, {})
    end
end
