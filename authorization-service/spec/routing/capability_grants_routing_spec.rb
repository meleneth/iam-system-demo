require "rails_helper"

RSpec.describe CapabilityGrantsController, type: :routing do
  describe "routing" do
    it "routes to #index" do
      expect(get: "/capability_grants").to route_to("capability_grants#index")
    end

    it "routes to #show" do
      expect(get: "/capability_grants/1").to route_to("capability_grants#show", id: "1")
    end


    it "routes to #create" do
      expect(post: "/capability_grants").to route_to("capability_grants#create")
    end

    it "routes to #update via PUT" do
      expect(put: "/capability_grants/1").to route_to("capability_grants#update", id: "1")
    end

    it "routes to #update via PATCH" do
      expect(patch: "/capability_grants/1").to route_to("capability_grants#update", id: "1")
    end

    it "routes to #destroy" do
      expect(delete: "/capability_grants/1").to route_to("capability_grants#destroy", id: "1")
    end
  end
end
