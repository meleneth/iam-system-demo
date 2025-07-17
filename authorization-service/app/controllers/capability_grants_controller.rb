class CapabilityGrantsController < ApplicationController
  before_action :set_capability_grant, only: %i[ show update destroy ]

  # GET /capability_grants
  def index
    @capability_grants = CapabilityGrant.all

    render json: @capability_grants
  end

  # GET /capability_grants/1
  def show
    render json: @capability_grant
  end

  # POST /capability_grants
  def create
    @capability_grant = CapabilityGrant.new(capability_grant_params)

    if @capability_grant.save
      render json: @capability_grant, status: :created, location: @capability_grant
    else
      render json: @capability_grant.errors, status: :unprocessable_entity
    end
  end

  # PATCH/PUT /capability_grants/1
  def update
    if @capability_grant.update(capability_grant_params)
      render json: @capability_grant
    else
      render json: @capability_grant.errors, status: :unprocessable_entity
    end
  end

  # DELETE /capability_grants/1
  def destroy
    @capability_grant.destroy!
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_capability_grant
      @capability_grant = CapabilityGrant.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through.
    def capability_grant_params
      params.require(:capability_grant).permit(
        :user_id, :permission, :scope_type, :scope_id
      )
    end
end
