# frozen_string_literal: true

class ScoreSentimentJob < ApplicationJob
	queue_as :default

	BATCH_SIZE = 200

	def perform
		scorer = Sentiment::SimpleLexiconScorer.new
		SentimentEvent.unscored.order(published_at: :asc).limit(BATCH_SIZE).find_each do |evt|
			begin
				score, conf = scorer.score([ evt.title, evt.meta.dig("summary") ].compact.join(". "))
				if score
					evt.update_columns(score: score, confidence: conf, updated_at: Time.now.utc)
				else
					evt.update_columns(score: 0.0, confidence: 0.0, updated_at: Time.now.utc)
				end
			rescue => e
				Rails.logger.error("ScoreSentimentJob failed for event #{evt.id}: #{e.class} #{e.message}")
			end
		end
	end
end