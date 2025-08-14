class SentimentController < ActionController::API
  # GET /sentiment/aggregates
  # Params:
  #   symbol: optional, defaults to BTC-USD-PERP
  #   window: optional, one of 5m,15m,1h; default 15m
  #   limit: optional, default 20
  def aggregates
    symbol = params[:symbol].presence || "BTC-USD-PERP"
    window = params[:window].presence || "15m"
    limit = (params[:limit] || 20).to_i.clamp(1, 200)

    records = SentimentAggregate.where(symbol: symbol, window: window).order(window_end_at: :desc).limit(limit)
    render json: {
      symbol: symbol,
      window: window,
      count: records.size,
      data: records.map { |r|
        {
          window_end_at: r.window_end_at,
          count: r.count,
          avg_score: r.avg_score.to_f,
          weighted_score: r.weighted_score.to_f,
          z_score: r.z_score.to_f
        }
      }
    }
  end
end
