# app/graphql/sources/groups_by_user_id.rb
module Sources
  class GroupsByUserId < BaseSource
    USER_ID_FETCH_CHUNK_SIZE = 200
    GROUP_ID_FETCH_CHUNK_SIZE = 200

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
                gus = keys.each_slice(USER_ID_FETCH_CHUNK_SIZE).flat_map do |user_ids|
                  GroupUser.search(user_id: user_ids)
                end
                group_ids = gus.map(&:group_id).uniq
                groups = group_ids.each_slice(GROUP_ID_FETCH_CHUNK_SIZE).flat_map do |ids|
                  Group.search(id: ids)
                end
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
