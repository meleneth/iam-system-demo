# frozen_string_literal: true

module Internal
  class DecisionsController < ApplicationController
    ALLOWED_QUESTIONS = [
      ["Account", "account.read"],
      ["Organization", "organization.read.accounts"]
    ].freeze

    def create
      actor = request.headers["HTTP_PAD_USER_ID"]
      if actor.blank? || %w[IAM_SYSTEM IAM_SYSTEM_AUTH].include?(actor)
        return render json: { error: "real actor required" }, status: :forbidden
      end

      targets = params[:targets]
      unless targets.is_a?(Array) && targets.any? && targets.size <= batch_size
        return render json: { error: "targets must be a nonempty bounded array" }, status: :bad_request
      end

      normalized = targets.map { |target| normalize_target(target) }
      capability_service = Authorization::Capabilities.new(user_id: actor)
      allowed_by_question = normalized.group_by { |target| [target.fetch(:scope_type), target.fetch(:permission)] }
        .to_h do |question, grouped|
          ids = grouped.map { |target| target.fetch(:scope_id) }
          allowed = case question
          when ["Account", "account.read"]
            capability_service.account_ids_with_permission(ids, "account.read")
          when ["Organization", "organization.read.accounts"]
            capability_service.organization_ids_with_permission(ids, "organization.read.accounts")
          end
          [question, allowed]
        end

      render json: { decisions: normalized.map do |target|
        question = [target.fetch(:scope_type), target.fetch(:permission)]
        target.merge(allowed: allowed_by_question.fetch(question).include?(target.fetch(:scope_id)))
      end }
    end

    private

    def batch_size
      Integer(ENV.fetch("IAM_DEMO_BATCH_SIZE", "1000"), 10).then do |size|
        raise ArgumentError unless (1..10_000).cover?(size)
        size
      end
    rescue ArgumentError
      raise ActionController::BadRequest, "invalid IAM_DEMO_BATCH_SIZE"
    end

    def normalize_target(raw_target)
      raw_keys = raw_target.respond_to?(:keys) ? raw_target.keys.map(&:to_s).sort : []
      target = raw_target.respond_to?(:permit) ? raw_target.permit(:scope_type, :scope_id, :permission).to_h : {}
      normalized = target.symbolize_keys.transform_values(&:to_s)
      question = [normalized[:scope_type], normalized[:permission]]
      unless raw_keys == %w[permission scope_id scope_type] &&
          ALLOWED_QUESTIONS.include?(question) && normalized[:scope_id].present?
        raise ActionController::BadRequest, "invalid decision target"
      end
      normalized
    end
  end
end
