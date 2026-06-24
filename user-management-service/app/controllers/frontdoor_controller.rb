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
        title: 'MSP reflected users 100k',
        detail: 'One MSP admin, 99,999 customer accounts, Redis-only reflected user-management grants.',
        query: <<~GRAPHQL
          {
            mspUserManagement(mspAccountId: "0f418549-dc1c-554e-947d-17c3a5154857", as: "f56f5767-fad2-57c9-b279-30463d7b3b90") {
              loading
              loadedCount
              totalCount
              message
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
        title: 'MSP reflected users 50k',
        detail: 'One MSP admin, 49,999 customer accounts, Redis-only reflected user-management grants.',
        query: <<~GRAPHQL
          {
            mspUserManagement(mspAccountId: "3c5b62df-e65e-5bdd-9798-de7c4e53315b", as: "4418a141-eeb1-50a9-893e-f94e2266a599") {
              loading
              loadedCount
              totalCount
              message
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
        title: 'MSP reflected users 10k',
        detail: 'One MSP admin, 9,999 customer accounts, Redis-only reflected user-management grants.',
        query: <<~GRAPHQL
          {
            mspUserManagement(mspAccountId: "b05e3a9d-ee13-5d71-b248-beaf964c893f", as: "f3a85e16-4fea-53c0-b31a-8ac822431f9a") {
              loading
              loadedCount
              totalCount
              message
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
