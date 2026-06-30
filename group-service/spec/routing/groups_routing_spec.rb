require "rails_helper"

RSpec.describe GroupsController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/groups").to route_to("groups#index")
    end

    it "routes to #show" do
      expect(get: "/groups/1").to route_to("groups#show", id: "1")
    end


    it "does not route to #create" do
      expect(post: "/groups").not_to be_routable
    end

    it "does not route to #update via PUT" do
      expect(put: "/groups/1").not_to be_routable
    end

    it "does not route to #update via PATCH" do
      expect(patch: "/groups/1").not_to be_routable
    end

    it "does not route to #destroy" do
      expect(delete: "/groups/1").not_to be_routable
    end
  end
end
