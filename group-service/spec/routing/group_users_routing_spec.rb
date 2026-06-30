require "rails_helper"

RSpec.describe GroupUsersController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/group_users").to route_to("group_users#index")
    end

    it "routes to #show" do
      expect(get: "/group_users/1").to route_to("group_users#show", id: "1")
    end


    it "does not route to #create" do
      expect(post: "/group_users").not_to be_routable
    end

    it "does not route to #update via PUT" do
      expect(put: "/group_users/1").not_to be_routable
    end

    it "does not route to #update via PATCH" do
      expect(patch: "/group_users/1").not_to be_routable
    end

    it "does not route to #destroy" do
      expect(delete: "/group_users/1").not_to be_routable
    end
  end
end
