require "rails_helper"

RSpec.describe OrganizationsController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/organizations").to route_to("organizations#index")
    end

    it "routes to #show" do
      expect(get: "/organizations/1").to route_to("organizations#show", id: "1")
    end


    it "does not route to #create" do
      expect(post: "/organizations").not_to be_routable
    end

    it "does not route to #update via PUT" do
      expect(put: "/organizations/1").not_to be_routable
    end

    it "does not route to #update via PATCH" do
      expect(patch: "/organizations/1").not_to be_routable
    end

    it "does not route to #destroy" do
      expect(delete: "/organizations/1").not_to be_routable
    end
  end
end
