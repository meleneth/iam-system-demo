basic account retrieval:

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

account_with_parents:

query {
  accountWithParents(id: "df18eccc-7aa5-4439-b3b4-87126feb3c0a", 
  as: "ad6b8ead-f107-40a8-904f-7c203d71bc70") {
    id
    name
    parentAccountId
  }
}

