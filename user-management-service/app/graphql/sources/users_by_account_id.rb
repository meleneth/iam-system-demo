# app/graphql/sources/users_by_account_id.rb
module Sources
  class UsersByAccountId < BaseSource
    # keys: [account_id]
    # result: [Array<User>] per account_id
    def fetch(keys)
      trace("User.find(:all, account_id: [#{keys.size} ids])") do
        grouped = Hash.new { |h, k| h[k] = [] }

        with_headers do
          User.with_headers('pad-user-id' => @as) do
            users = keys.empty? ? [] : User.find(:all, params: { account_id: keys })
            users.each { |u| grouped[u.account_id] << u }
          end
        end

        keys.map { |k| grouped[k] }
      end
    end
  end
end
