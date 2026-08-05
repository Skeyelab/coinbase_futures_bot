require_relative "../lib/cities"

RSpec.describe Cities do
  describe "station verification" do
    # The original seven name their station in the market's own rules text
    # ("Central Park", "Chicago Midway"). The twelve added 2026-08-04 say only
    # "at Atlanta", "at Phoenix" -- no station at all. Chicago settling on
    # Midway rather than O'Hare is exactly this class of error, so an unverified
    # mapping must not be tradeable.
    it "marks the rules-quoted cities as verified" do
      verified = described_class::ALL.select { |c| c[:verified] }

      expect(verified.map { |c| c[:series] }).to include("KXHIGHNY", "KXHIGHCHI", "KXHIGHAUS")
      expect(verified.size).to eq(7)
    end

    it "marks the inferred-station cities as unverified" do
      unverified = described_class::ALL.reject { |c| c[:verified] }

      expect(unverified.size).to eq(12)
      expect(unverified.map { |c| c[:series] }).to include("KXHIGHTATL", "KXHIGHTDC", "KXHIGHTPHX")
    end

    it "gives every city a station and a zone" do
      described_class::ALL.each do |c|
        expect(c[:station]).to match(/\AK[A-Z]{3}\z/), "#{c[:series]} station"
        expect { TZInfo::Timezone.get(c[:time_zone]) }.not_to raise_error, "#{c[:series]} zone"
      end
    end

    # Arizona does not observe daylight saving. Using America/Denver would put
    # the local day boundary an hour out all summer, which silently reassigns
    # late-evening peaks to the wrong day.
    it "puts Phoenix in America/Phoenix, not America/Denver" do
      phx = described_class::ALL.find { |c| c[:series] == "KXHIGHTPHX" }

      expect(phx[:time_zone]).to eq("America/Phoenix")
    end
  end
end
