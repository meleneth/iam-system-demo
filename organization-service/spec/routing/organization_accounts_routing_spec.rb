require "rails_helper"

RSpec.describe OrganizationAccountsController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/organization_accounts").to route_to("organization_accounts#index")
    end

    it "routes to #show" do
      expect(get: "/organization_accounts/1").to route_to("organization_accounts#show", id: "1")
    end


    it "does not route to #create" do
      expect(post: "/organization_accounts").not_to be_routable
    end

    it "does not route to #update via PUT" do
      expect(put: "/organization_accounts/1").not_to be_routable
    end

    it "does not route to #update via PATCH" do
      expect(patch: "/organization_accounts/1").not_to be_routable
    end

    it "does not route to #destroy" do
      expect(delete: "/organization_accounts/1").not_to be_routable
    end
  end
end
