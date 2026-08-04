require_relative "../lib/release_detector"

RSpec.describe ReleaseDetector do
  # The live BLS page renders the headline as:
  #   "Total nonfarm payroll employment (+57,000) and the unemployment rate ..."
  def page(text)
    "<html><body><p>#{text}</p></body></html>"
  end

  let(:june) do
    page("Total nonfarm payroll employment (+57,000) and the unemployment rate " \
         "(4.1 percent) changed little in June, the U.S. Bureau of Labor Statistics reported today.")
  end

  describe ".observe" do
    it "pulls the headline payrolls change out of the release" do
      expect(described_class.observe(june)[:payrolls]).to eq(57_000)
    end

    it "reads a negative print as negative" do
      body = page("Total nonfarm payroll employment (-12,000) and the unemployment rate (4.4 percent)")

      expect(described_class.observe(body)[:payrolls]).to eq(-12_000)
    end

    it "reads the unemployment rate too" do
      expect(described_class.observe(june)[:unemployment]).to eq(4.1)
    end

    # A bare "(57,000)" elsewhere on the page is some other figure. Requiring the
    # sign is what keeps a table cell from being mistaken for the headline.
    it "ignores an unsigned number that is not the headline change" do
      body = page("Total nonfarm payroll employment (57,000) in some other context")

      expect(described_class.observe(body)[:payrolls]).to be_nil
    end

    it "reports nothing rather than guessing when the release is not on the page" do
      observed = described_class.observe(page("The page you requested is unavailable."))

      expect(observed[:payrolls]).to be_nil
      expect(observed[:unemployment]).to be_nil
    end

    it "survives an empty or missing body" do
      expect { described_class.observe("") }.not_to raise_error
      expect { described_class.observe(nil) }.not_to raise_error
      expect(described_class.observe(nil)[:payrolls]).to be_nil
    end
  end

  describe "publication detection" do
    # The number changing IS the publication signal. Digest alone would fire on
    # unrelated page churn; the number alone would miss two identical prints.
    it "changes both number and digest when a new month lands" do
      july = page("Total nonfarm payroll employment (+104,000) and the unemployment rate (4.2 percent)")

      before = described_class.observe(june)
      after = described_class.observe(july)

      expect(after[:payrolls]).not_to eq(before[:payrolls])
      expect(after[:digest]).not_to eq(before[:digest])
    end

    # Whitespace and markup churn must NOT read as a publication, or the
    # recorder stamps t_published on a page reflow.
    it "keeps the same digest when only markup and spacing change" do
      reflowed = june.gsub("<p>", "<p >\n   ").gsub(" and ", "  and\n")

      expect(described_class.observe(reflowed)[:digest]).to eq(described_class.observe(june)[:digest])
    end

    # Two months printing the identical headline is unlikely but possible, and
    # the digest is the only thing that would catch it.
    it "still moves the digest when the number repeats but the text differs" do
      repeat = page("Total nonfarm payroll employment (+57,000) and the unemployment rate (4.3 percent)")

      expect(described_class.observe(repeat)[:payrolls]).to eq(described_class.observe(june)[:payrolls])
      expect(described_class.observe(repeat)[:digest]).not_to eq(described_class.observe(june)[:digest])
    end
  end
end
