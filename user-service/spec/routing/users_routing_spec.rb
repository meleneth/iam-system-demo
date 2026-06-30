require "rails_helper"

RSpec.describe UsersController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/users").to route_to("users#index")
    end

    it "routes to #show" do
      expect(get: "/users/1").to route_to("users#show", id: "1")
    end


    it "does not route to #create" do
      expect(post: "/users").not_to be_routable
    end

    it "does not route to #update via PUT" do
      expect(put: "/users/1").not_to be_routable
    end

    it "does not route to #update via PATCH" do
      expect(patch: "/users/1").not_to be_routable
    end

    it "does not route to #destroy" do
      expect(delete: "/users/1").not_to be_routable
    end
  end
end
