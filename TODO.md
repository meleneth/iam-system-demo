System Map

user-management-service: User Interface Layer
be able to look at organizations
be able to impersonate a user (view the user management screen as a particular user)
build the flat account cache layer

accounts have parent_account_id, which makes for bad times when querying - n+1 in effect

plan - flat account 'view'

gemify organization-service/lib/mel/filterable.rb

gemify ActiveResource models individually

Actually Do Soon:

add a same_org scoped support for organization_accounts/for/:account_id that saves from having to get the org id then ask again for the org accounts


