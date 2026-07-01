# frozen_string_literal: true

class MetricsController < ActionController::API
  def show
    render plain: IamDemo::CacheMetrics.prometheus_text, content_type: "text/plain; version=0.0.4"
  end
end
