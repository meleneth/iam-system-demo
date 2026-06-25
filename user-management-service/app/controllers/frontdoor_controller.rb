class FrontdoorController < ApplicationController
  RANDOM_RECORD_ATTEMPTS = 25
  RANDOM_RECORD_DISPLAY_LIMIT = 500

  def index
    @query_links = demo_queries.values
    @jaeger_links = jaeger_links
    @experimental_links = experimental_links
    @msp_user_management_links = msp_user_management_links
  end

  def random_record
    @attempts = []
    selection = find_random_admin_visible_org

    unless selection
      @error = "Could not find a random organization with a native admin grant after #{RANDOM_RECORD_ATTEMPTS} attempts."
      return render :random_record
    end

    return redirect_to random_record_detail_path(
      organization_id: selection.fetch(:organization).id,
      account_id: selection.fetch(:account_id)
    )
  end

  def random_record_detail
    permitted = params.permit(:organization_id, :account_id)
    # AUTH HACKING: required for demo functionality. Stable refresh needs to rehydrate the selected org ID from the URL;
    # a production caller should not be able to turn an arbitrary org ID into org details without prior authorization.
    organization = Organization.with_headers("pad-user-id" => "IAM_SYSTEM") do
      Organization.find(permitted.fetch(:organization_id))
    end
    selection = selection_for_random_account(organization, permitted.fetch(:account_id))

    unless selection
      @error = "Could not find a native admin grant for organization #{organization.id} or its MSP, if managed."
      @attempts = [
        {
          organization_id: organization.id,
          account_id: permitted.fetch(:account_id),
          admin_user_id: nil,
          msp_managed: false
        }
      ]
      return render :random_record
    end

    @organization = selection.fetch(:organization)
    @selected_account_id = selection.fetch(:account_id)
    @admin_user_id = selection.fetch(:admin_user_id)
    @msp_relationship = selection[:msp_relationship]

    if @msp_relationship
      load_msp_managed_detail
    else
      load_native_org_detail
    end

    render :random_record
  end

  def demo_query
    @demo_query = demo_queries.fetch(params[:id])
    render layout: false
  rescue KeyError
    raise ActionController::RoutingError, "Unknown demo query: #{params[:id]}"
  end

  def msp_graphql_query
    permitted = params.permit(:kind, :msp_account_id, :admin_user_id, :continuance)
    @demo_query = dynamic_msp_query(
      kind: permitted.fetch(:kind),
      msp_account_id: permitted.fetch(:msp_account_id),
      admin_user_id: permitted.fetch(:admin_user_id),
      continuance: permitted[:continuance]
    )
    render :demo_query, layout: false
  end

  private

  def find_random_admin_visible_org
    RANDOM_RECORD_ATTEMPTS.times do
      # AUTH HACKING: required for demo functionality. This deliberately enumerates an org ID the caller does not already know,
      # which would violate the production security model.
      Organization.with_headers("pad-user-id" => "IAM_SYSTEM") do
        organization = Organization.random_internal
        # AUTH HACKING: required for demo functionality. This deliberately discovers an account ID inside that org,
        # which a normal caller should not be able to learn unless already authorized in that context.
        OrganizationAccount.with_headers("pad-user-id" => "IAM_SYSTEM") do
          random_account = OrganizationAccount.random_account_for_organization(organization.id)
          selection = selection_for_random_account(organization, random_account.fetch(:account_id))
          @attempts << {
            organization_id: organization.id,
            account_id: random_account.fetch(:account_id),
            admin_user_id: selection&.fetch(:admin_user_id, nil),
            msp_managed: selection&.key?(:msp_relationship) || false
          }
          return selection if selection
        end
      end
    end

    nil
  end

  def selection_for_random_account(organization, account_id)
    # AUTH HACKING: required for demo functionality. MSP mappings are private/internal; a non-system caller should
    # not be able to discover that this managed account is attached to an MSP unless they already know that relationship.
    manager = MspManagedAccount.manager_for(account_id)
    if manager.fetch(:managed)
      msp_account_id = manager.fetch(:msp_account_id)
      # AUTH HACKING: required for demo functionality. This walks from a private MSP account ID to its owning org
      # solely to bootstrap the demo actor; that identity discovery would not exist in production.
      msp_org_payload = OrganizationAccount.with_headers("pad-user-id" => "IAM_SYSTEM") do
        OrganizationAccount.account_ids_for_organization_by_account_id(msp_account_id)
      end
      msp_organization = msp_org_payload.fetch(:organization)
      admin = admin_for_organization(msp_organization.id)
      return nil unless admin

      return {
        organization: organization,
        account_id: account_id,
        admin_user_id: admin.fetch(:user_id),
        msp_relationship: {
          msp_account_id: msp_account_id,
          msp_organization_id: msp_organization.id,
          msp_account_count: msp_org_payload.fetch(:account_ids).length
        }
      }
    end

    admin = admin_for_organization(organization.id)
    return nil unless admin

    {
      organization: organization,
      account_id: account_id,
      admin_user_id: admin.fetch(:user_id)
    }
  end

  def admin_for_organization(organization_id)
    # AUTH HACKING: required for demo functionality. This discovers an admin user ID for an org the caller may not
    # otherwise know; production callers must arrive with an identity, not ask the system to reveal one.
    CapabilityGrant.with_headers("pad-user-id" => "IAM_SYSTEM") do
      CapabilityGrant.admin_user_for_organization(organization_id)
    end
  end

  def load_native_org_detail
    Organization.with_headers("pad-user-id" => @admin_user_id) do
      @organization = Organization.find(@organization.id)
    end

    OrganizationAccount.with_headers("pad-user-id" => @admin_user_id) do
      @account_count = OrganizationAccount.accounts_counts(@organization.id).fetch(:accounts_count).to_i
      @organization_account_links = OrganizationAccount.find(:all, params: { organization_id: @organization.id })
    end

    @account_ids = @organization_account_links.map { |link| link.account_id.to_s }
    @user_counts_by_account_id = user_counts_for(@account_ids)
    @total_user_count = @user_counts_by_account_id.values.sum

    @display_account_ids = @account_ids.first(RANDOM_RECORD_DISPLAY_LIMIT)
    @accounts_by_id = fetch_accounts_for(@display_account_ids)
  end

  def load_msp_managed_detail
    @account_ids = [@selected_account_id]
    @account_count = 1
    @msp_reflected_status = MspReflectedUserGrant.check(
      user_id: @admin_user_id,
      msp_account_id: @msp_relationship.fetch(:msp_account_id),
      account_ids: @account_ids
    )
    @user_counts_by_account_id = user_counts_for(@account_ids)
    @total_user_count = @user_counts_by_account_id.values.sum
    @display_account_ids = @account_ids
    @accounts_by_id = {}
  end

  def user_counts_for(account_ids)
    User.with_headers("pad-user-id" => @admin_user_id) do
      account_ids.each_slice(500).each_with_object({}) do |ids, counts|
        counts.merge!(User.users_count(ids).transform_keys(&:to_s))
      end
    end
  end

  def fetch_accounts_for(account_ids)
    Account.with_headers("pad-user-id" => @admin_user_id) do
      account_ids.each_slice(100).flat_map { |ids| Account.where(id: ids).to_a }.index_by { |account| account.id.to_s }
    end
  end

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
              continuance
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
              continuance
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
              continuance
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

  def dynamic_msp_query(kind:, msp_account_id:, admin_user_id:, continuance: nil)
    case kind
    when "accounts"
      {
        title: "MSP reflected accounts",
        query: msp_user_management_query(
          msp_account_id: msp_account_id,
          admin_user_id: admin_user_id,
          continuance: continuance,
          body: <<~GRAPHQL
            accounts {
              id
            }
          GRAPHQL
        )
      }
    when "full"
      {
        title: "MSP reflected users and groups",
        query: msp_user_management_query(
          msp_account_id: msp_account_id,
          admin_user_id: admin_user_id,
          continuance: continuance,
          body: <<~GRAPHQL
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
          GRAPHQL
        )
      }
    else
      raise ActionController::RoutingError, "Unknown MSP GraphQL query: #{kind}"
    end
  end

  def msp_user_management_query(msp_account_id:, admin_user_id:, continuance:, body:)
    args = {
      mspAccountId: msp_account_id,
      as: admin_user_id
    }
    args[:continuance] = continuance if continuance.present?
    argument_source = args.map { |key, value| "#{key}: #{value.to_s.to_json}" }.join(", ")

    <<~GRAPHQL
      {
        mspUserManagement(#{argument_source}) {
          loading
          loadedCount
          totalCount
          continuance
          message
      #{body.indent(4)}
        }
      }
    GRAPHQL
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

  def msp_user_management_links
    [
      ['MSP 100k user management', organization_user_management_path(msp_account_id: '0f418549-dc1c-554e-947d-17c3a5154857', as: 'f56f5767-fad2-57c9-b279-30463d7b3b90')],
      ['MSP 50k user management', organization_user_management_path(msp_account_id: '3c5b62df-e65e-5bdd-9798-de7c4e53315b', as: '4418a141-eeb1-50a9-893e-f94e2266a599')],
      ['MSP 10k user management', organization_user_management_path(msp_account_id: 'b05e3a9d-ee13-5d71-b248-beaf964c893f', as: 'f3a85e16-4fea-53c0-b31a-8ac822431f9a')]
    ]
  end
end
