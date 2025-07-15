System Map

user-management-service: User Interface Layer
be able to look at organizations
be able to impersonate a user (view the user management screen as a particular user)
build the flat account cache layer

accounts have parent_account_id, which makes for bad times when querying - n+1 in effect

plan - flat account 'view'

gemify organization-service/lib/mel/filterable.rb
