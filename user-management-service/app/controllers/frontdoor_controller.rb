class FrontdoorController < ApplicationController
  def index
    @query_links = demo_queries.values
    @jaeger_links = jaeger_links
    @experimental_links = experimental_links
  end

  def demo_query
    @demo_query = demo_queries.fetch(params[:id])
    render layout: false
  rescue KeyError
    raise ActionController::RoutingError, "Unknown demo query: #{params[:id]}"
  end

  private

  def demo_queries
    {
      'deep-chain' => {
        id: 'deep-chain',
        title: 'Deep chain parent walk',
        detail: '25-level account ancestry, authorized as the root account admin.',
        query: <<~GRAPHQL
          {
            accountWithParents(id: "ed253374-9a50-51cd-ac06-d0d636dd42bd", as: "f9684f2b-2fd0-5dd0-b783-9cb238dbc396") {
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
        GRAPHQL
      },
      'wide-org' => {
        id: 'wide-org',
        title: 'Wide organization users and groups',
        detail: 'One root with 250 child accounts, authorized as the root account admin.',
        query: <<~GRAPHQL
          {
            organization(id: "359f5f4d-3032-5a06-b36c-d820be488ae4", as: "92687b83-c34a-5d06-8dcb-d659b6506bd0") {
              id
              name
              accounts {
                id
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
        GRAPHQL
      },
      'dense-account' => {
        id: 'dense-account',
        title: 'Dense account users and groups',
        detail: 'One top-level account with 20,000 users and multiple groups.',
        query: <<~GRAPHQL
          {
            account(id: "bcd6677f-a4b2-517c-a8c8-ba4096147509", as: "169bdb5e-57a1-53a8-ae8c-028da169baf9") {
              id
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
        GRAPHQL
      },
      'massive-fanout-100k' => {
        id: 'massive-fanout-100k',
        title: 'Massive fanout 100k',
        detail: '100,000 users across nearly 100,000 accounts, authorized as the root admin.',
        query: <<~GRAPHQL
          {
            organization(id: "97c51e2b-d056-5a0f-81ec-79677720a6cf", as: "5138ea60-cd59-5f63-a280-db91d43783d2") {
              id
              name
              accounts {
                id
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
        GRAPHQL
      },
      'massive-fanout-50k' => {
        id: 'massive-fanout-50k',
        title: 'Massive fanout 50k',
        detail: '50,000 users across nearly 50,000 accounts, authorized as the root admin.',
        query: <<~GRAPHQL
          {
            organization(id: "eb21d6a4-b6bc-56e8-a0db-bcea6f8f0647", as: "894c2cfb-02e6-5be4-b48e-f14cae31683b") {
              id
              name
              accounts {
                id
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
        GRAPHQL
      },
      'massive-fanout-10k' => {
        id: 'massive-fanout-10k',
        title: 'Massive fanout 10k',
        detail: '10,000 users across nearly 10,000 accounts, authorized as the root admin.',
        query: <<~GRAPHQL
          {
            organization(id: "fc75e5e0-e369-5572-9f47-8156103aa525", as: "e9c7f330-e3c0-5e53-ad59-5d131227f318") {
              id
              name
              accounts {
                id
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
        GRAPHQL
      }
    }
  end

  def jaeger_links
    [
      ['Jaeger home', 'http://localhost:11160/'],
      ['user-management-service traces', 'http://localhost:11160/search?service=user-management-service'],
      ['account-service traces', 'http://localhost:11160/search?service=account-service'],
      ['organization-service traces', 'http://localhost:11160/search?service=organization-service'],
      ['authorization-service traces', 'http://localhost:11160/search?service=authorization-service'],
      ['user-service traces', 'http://localhost:11160/search?service=user-service'],
      ['group-service traces', 'http://localhost:11160/search?service=group-service']
    ]
  end

  def experimental_links
    [
      ['Deep chain account page as root admin', '/accounts/ed253374-9a50-51cd-ac06-d0d636dd42bd?as=f9684f2b-2fd0-5dd0-b783-9cb238dbc396'],
      ['Branching tree account page as root admin', '/accounts/0a64f8dd-f5bc-5bbe-ac30-43ddabfd3826?as=3914fd49-77a1-55b3-9326-8035926bd29a'],
      ['Dense account page as top-level admin', '/accounts/bcd6677f-a4b2-517c-a8c8-ba4096147509?as=169bdb5e-57a1-53a8-ae8c-028da169baf9']
    ]
  end
end
