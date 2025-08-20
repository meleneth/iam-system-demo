# app/graphql/sources/accounts_with_parents_by_id.rb
module Sources
  class AccountsWithParentsById < BaseSource
    # keys: [account_id]
    # result: [Array<Account>]    (each key returns the array [account, parent, grandparent, ...])
    def fetch(keys)
      trace("Account.with_parents_batch(#{keys.size})") do
        results_by_key = {}

        with_headers do
          Account.with_headers('pad-user-id' => @as) do
            # Prefer a batched endpoint if you have it:
            keys.each { |k| results_by_key[k] = Array(Account.with_parents(k)) }
          end
        end

        keys.map { |k| results_by_key[k] || [] }
      end
    end
  end
end
