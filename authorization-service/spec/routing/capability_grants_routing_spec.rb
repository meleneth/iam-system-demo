require "rails_helper"
require "securerandom"

RSpec.describe "capability grant routing", type: :routing do
  it "does not expose raw grant collection or member routes" do
    expect(get: "/capability_grants").not_to be_routable
    expect(get: "/capability_grants/#{SecureRandom.uuid}").not_to be_routable
    expect(post: "/capability_grants").not_to be_routable
    expect(patch: "/capability_grants/#{SecureRandom.uuid}").not_to be_routable
    expect(delete: "/capability_grants/#{SecureRandom.uuid}").not_to be_routable
  end
end
