
account = Account.create
user = User.create(email: "bleh@example.com", account_id: account.id)

ap account.instance_variable_get(:@attributes)
ap user.instance_variable_get(:@attributes)
