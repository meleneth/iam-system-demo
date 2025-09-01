# app/graphql/sources/groups_by_user_id.rb
module Sources
  class GroupsByUserId < BaseSource
    # keys: [user_id]
    # result: [Array<Group>] per user_id
    def initialize(as:, otel_ctx:, tracer:)
      @as = as
      @otel_ctx = otel_ctx
      @tracer = tracer
    end

    def fetch(keys)
      OpenTelemetry::Context.with_current(@otel_ctx) do |span|
        trace("GroupUser & Group batch (users: #{keys.size})") do
          groups_by_user = Hash.new { |h, k| h[k] = [] }

          with_headers do
            GroupUser.with_headers('pad-user-id' => @as) do
              Group.with_headers('pad-user-id' => @as) do
                gus = keys.empty? ? [] : GroupUser.find(:all, params: { user_id: keys })
                group_ids = gus.map(&:group_id).uniq
                groups    = group_ids.empty? ? [] : Group.find(:all, params: { id: group_ids })
                groups_by_id = groups.index_by(&:id)

                gus.each do |gu|
                  if (g = groups_by_id[gu.group_id])
                    groups_by_user[gu.user_id] << g
                  end
                end
              end
            end
          end

          keys.map { |k| groups_by_user[k] }
        end
      end
    end
  end
end
