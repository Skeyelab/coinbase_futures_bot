# frozen_string_literal: true

namespace :sentiment do
  desc "Forward predictiveness: does sentiment z-score predict forward price returns? " \
       "Usage: rake sentiment:predictiveness[OIL-USD,NOL-19AUG26-CDE,4,14]"
  task :predictiveness, [:sentiment_symbol, :price_symbol, :horizon_hours, :days] => :environment do |_t, args|
    sentiment_symbol = args[:sentiment_symbol] || "OIL-USD"
    price_symbol = args[:price_symbol]
    days = (args[:days] || "30").to_i
    horizons = (args[:horizon_hours] ? [args[:horizon_hours].to_i] : [1, 4, 24])

    # Resolve the oil price symbol to whatever NOL contract has data if not given.
    price_symbol ||= Candle.where("symbol LIKE ?", "NOL%").where(timeframe: "1h")
      .group(:symbol).order(Arel.sql("COUNT(*) DESC")).limit(1).count.keys.first

    unless price_symbol
      puts "No price symbol found (pass one explicitly). Aborting."
      next
    end

    from = days.days.ago
    to = Time.current
    puts "Sentiment predictiveness: #{sentiment_symbol} z-score -> #{price_symbol} forward return"
    puts "Window: last #{days}d (#{from.utc.strftime("%Y-%m-%d")} .. #{to.utc.strftime("%Y-%m-%d")})"
    puts "-" * 72
    printf("%-10s %6s %8s %12s %10s %14s\n", "horizon", "n", "signals", "correlation", "hit_rate", "mean_fwd_ret")

    horizons.each do |h|
      r = Sentiment::PredictivenessStudy.new(
        sentiment_symbol: sentiment_symbol, price_symbol: price_symbol, horizon_hours: h
      ).run(from: from, to: to)

      fmt = ->(v, p = 3) { v.nil? ? "n/a" : v.round(p).to_s }
      printf("%-10s %6d %8d %12s %10s %14s\n",
        "#{h}h", r[:n], r[:signal_count], fmt.call(r[:correlation]), fmt.call(r[:hit_rate], 2),
        r[:mean_forward_return] ? "#{(r[:mean_forward_return] * 100).round(3)}%" : "n/a")
    end

    puts "-" * 72
    puts "Note: needs weeks of data to be meaningful. correlation ~ z-vs-return; " \
         "hit_rate = of |z|>=1 signals, share whose direction matched."
  end
end
