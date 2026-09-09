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
            request_headers = { 'pad-user-id' => @as }
            GroupUser.with_headers(request_headers) do
              Group.with_headers(request_headers) do
                gus = keys.each_slice(IamDemo.batch_size).flat_map do |user_ids|
                  GroupUser.search(user_id: user_ids)
                end
                group_ids = gus.map(&:group_id).uniq
                groups = group_ids.each_slice(IamDemo.batch_size).flat_map do |ids|
                  Group.search(id: ids)
                end
                groups_by_id = groups.index_by(&:id)

                gus.each do |gu|
                  group = groups_by_id.fetch(gu.group_id) do
                    raise GraphQL::ExecutionError, "Group Service omitted a group referenced by a membership"
                  end
                  groups_by_user[gu.user_id] << group
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
