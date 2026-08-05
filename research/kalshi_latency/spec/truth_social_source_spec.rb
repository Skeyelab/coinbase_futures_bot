require "base64"
require "json"
require_relative "../lib/truth_social_source"

RSpec.describe TruthSocialSource do
  # trumpstruth.org is Roll Call's tracker, which is the SETTLEMENT SOURCE
  # named in the KXTRUTHSOCIAL rules -- not a proxy for it. That distinction
  # is why this is worth reading at all: Kalshi crypto settles on CF
  # Benchmarks RTI, and reading Coinbase spot instead was wrong.
  describe ".cursor_for" do
    # The site's own next-cursor stalls after one page. Constructed cursors do
    # not, which is the only way to reach back past ~28 hours.
    it "builds the base64 cursor the site expects" do
      cursor = described_class.cursor_for("2026-08-02 00:00:00")

      expect(JSON.parse(Base64.decode64(cursor)))
        .to eq("status_created_at" => "2026-08-02 00:00:00", "_pointsToNextItems" => true)
    end
  end

  describe ".status_ids" do
    # Permalinks appear more than once per post (permalink plus share link), so
    # a naive scan double-counts every post in the week.
    it "counts each post once however many times it is linked" do
      html = <<~HTML
        <a href="https://trumpstruth.org/statuses/40580">read</a>
        <a href="https://trumpstruth.org/statuses/40580">share</a>
        <a href="https://trumpstruth.org/statuses/40579">read</a>
      HTML

      expect(described_class.status_ids(html)).to eq([40_579, 40_580])
    end

    it "returns them ascending so a boundary comparison is meaningful" do
      html = "/statuses/40600 /statuses/40100 /statuses/40350".gsub("/statuses", "trumpstruth.org/statuses")

      expect(described_class.status_ids(html)).to eq([40_100, 40_350, 40_600])
    end

    it "finds nothing in a page with no posts" do
      expect(described_class.status_ids("<html><body>nothing here</body></html>")).to eq([])
      expect(described_class.status_ids(nil)).to eq([])
    end

    # A link to some other path that happens to contain digits must not be
    # counted as a post.
    it "ignores urls that are not status permalinks" do
      html = %(<a href="https://trumpstruth.org/about/2026">x</a><a href="/users/40580">y</a>)

      expect(described_class.status_ids(html)).to eq([])
    end
  end
end
