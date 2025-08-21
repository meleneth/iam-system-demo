# basic account retrieval:

    {
      account(
        id: "df18eccc-7aa5-4439-b3b4-87126feb3c0a"
        as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
      ) {
        id
        name
        parentAccountId
      }
    }

# account_with_parents:

    query {
      accountWithParents(id: "df18eccc-7aa5-4439-b3b4-87126feb3c0a", 
      as: "ad6b8ead-f107-40a8-904f-7c203d71bc70") {
        id
        name
        parentAccountId
      }
    }

# account_with_parents, including users per account:

    {
      accountWithParents(
        id: "df18eccc-7aa5-4439-b3b4-87126feb3c0a"
        as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
      ) {
        id
        name
        parentAccountId
        users {
          id
          email
          accountId
        }
      }
    }

# account_with_parents, including users per account and groups:
    {
      accountWithParents(
        id: "df18eccc-7aa5-4439-b3b4-87126feb3c0a"
        as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
      ) {
        id
        name
        parentAccountId
        users {
          id
          email
          accountId
          groups {
            id
            name
          }
        }
      }
    }

# Organization direct query
    {
      organization(
        id: "a7f2fa09-a480-4974-ab4b-f6c20e1f8a72"
        as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
      ) {
        id
        name
        accounts {
          name
          users {
            id
            email
            accountId
            groups {
              id
              name
            }
          }
        }
      }
    }

# direct account query
    {
      account(
        id: "b130226a-1177-41af-a7e4-519546fd4b36"
        as: "ad6b8ead-f107-40a8-904f-7c203d71bc70"
      ) {
        name
        users {

          id
          email
          accountId
          groups {
            id
            name
          }
        }
      }
    }

# multiple accounts example:
    query GetManyAccounts($ids: [ID!]!, $as: ID!) {
      accounts(ids: $ids, as: $as) {
        id
        name
      }
    }

and variables:

    {
      "ids": [
        "845705e1-d59e-441d-9a66-432b8c211754",
        "cd56c690-e39e-46c0-bca6-94bde44fb85a"
      ],
      "as": "ad6b8ead-f107-40a8-904f-7c203d71bc70"
    }
