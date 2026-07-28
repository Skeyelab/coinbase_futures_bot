# frozen_string_literal: true

namespace :sentiment do
  desc "Recompute raw_text_hash after the dedup normalization change; collapses case/whitespace duplicates"
  task rehash: :environment do
    # Without this, normalizing the hash makes every stored row unmatchable and
    # the next fetch re-inserts the lot — inflating exactly the inflow metric
    # the change exists to make honest.
    updated = 0
    collapsed = 0
    seen = {}

    SentimentEvent.find_each do |e|
      want = Digest::SHA256.hexdigest(
        Sentiment::BaseNewsClient.normalized_hash_input(e.url, e.title, e.symbol)
      )
      key = [e.source, want]
      if seen.key?(key)
        e.destroy
        collapsed += 1
        next
      end
      seen[key] = true
      next if e.raw_text_hash == want

      e.update_columns(raw_text_hash: want, updated_at: Time.current)
      updated += 1
    end

    puts "rehashed #{updated} event(s); removed #{collapsed} case/whitespace duplicate(s)"
  end
end
