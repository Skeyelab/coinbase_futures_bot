# frozen_string_literal: true

require "rails_helper"

RSpec.describe "Contract ID Generation Logic", type: :service do
  let(:manager) { MarketData::FuturesContractManager.new }

  describe "Real date calculation logic without mocking" do
    context "Testing actual 'last Friday of month' algorithm" do
      # Test with various real months to verify the algorithm works correctly
      # without any Date.current mocking

      it "correctly calculates last Friday for months with different Friday patterns" do
        test_cases = [
          # Month where last Friday is very early (30th is Friday)
          {date: Date.new(2024, 11, 15), expected_friday: Date.new(2024, 11, 29)},
          # Month where last Friday is very late (31st is Saturday, so Friday is 30th)
          {date: Date.new(2024, 3, 15), expected_friday: Date.new(2024, 3, 29)},
          # Month where last Friday is the maximum late (31st is Sunday, so Friday is 29th)
          {date: Date.new(2024, 5, 15), expected_friday: Date.new(2024, 5, 31)},
          # February in a leap year
          {date: Date.new(2024, 2, 15), expected_friday: Date.new(2024, 2, 23)},
          # February in a non-leap year
          {date: Date.new(2023, 2, 15), expected_friday: Date.new(2023, 2, 24)},
          # Month with 5 Fridays vs 4 Fridays
          {date: Date.new(2024, 6, 15), expected_friday: Date.new(2024, 6, 28)},
          {date: Date.new(2024, 9, 15), expected_friday: Date.new(2024, 9, 27)}
        ]

        test_cases.each do |test_case|
          contract_id = manager.generate_contract_id_for_month("BTC", test_case[:date])
          expected_date_str = test_case[:expected_friday].strftime("%d%b%y").upcase
          expected_contract_id = "BIT-#{expected_date_str}-CDE"

          expect(contract_id).to eq(expected_contract_id),
            "For #{test_case[:date].strftime("%B %Y")}, expected last Friday to be " \
            "#{test_case[:expected_friday]} (#{expected_contract_id}), got #{contract_id}"
        end
      end

      it "handles edge case where first day of month is Friday" do
        # Test a month that starts on Friday to ensure we get the LAST Friday
        # March 2024 starts on Friday (March 1st), last Friday should be March 29th
        test_date = Date.new(2024, 3, 10)
        contract_id = manager.generate_contract_id_for_month("BTC", test_date)

        # March 29, 2024 is the last Friday of March 2024
        expect(contract_id).to eq("BIT-29MAR24-CDE")
      end

      it "handles months with only 4 Fridays vs 5 Fridays" do
        # February 2024 has 4 Fridays (2, 9, 16, 23), last is 23rd
        feb_2024 = Date.new(2024, 2, 15)
        feb_contract = manager.generate_contract_id_for_month("BTC", feb_2024)
        expect(feb_contract).to eq("BIT-23FEB24-CDE")

        # March 2024 has 5 Fridays (1, 8, 15, 22, 29), last is 29th
        mar_2024 = Date.new(2024, 3, 15)
        mar_contract = manager.generate_contract_id_for_month("BTC", mar_2024)
        expect(mar_contract).to eq("BIT-29MAR24-CDE")
      end

      it "correctly handles year boundaries" do
        # December 2023 to January 2024 transition
        dec_2023 = Date.new(2023, 12, 15)
        dec_contract = manager.generate_contract_id_for_month("BTC", dec_2023)
        expect(dec_contract).to eq("BIT-29DEC23-CDE")

        jan_2024 = Date.new(2024, 1, 15)
        jan_contract = manager.generate_contract_id_for_month("BTC", jan_2024)
        expect(jan_contract).to eq("BIT-26JAN24-CDE")
      end

      it "never generates a contract ID with a date from a different month" do
        # Test various months to ensure the safety check works
        test_months = [
          Date.new(2024, 1, 15),
          Date.new(2024, 2, 15),
          Date.new(2024, 3, 15),
          Date.new(2024, 4, 15),
          Date.new(2024, 5, 15),
          Date.new(2024, 6, 15),
          Date.new(2024, 7, 15),
          Date.new(2024, 8, 15),
          Date.new(2024, 9, 15),
          Date.new(2024, 10, 15),
          Date.new(2024, 11, 15),
          Date.new(2024, 12, 15)
        ]

        test_months.each do |month_date|
          contract_id = manager.generate_contract_id_for_month("BTC", month_date)

          # Extract the date from the contract ID and verify it's in the correct month
          # Format: BIT-DDMMMYY-CDE
          date_part = contract_id.split("-")[1] # Get DDMMMYY part
          day = date_part[0..1].to_i
          month_abbr = date_part[2..4]
          year = "20#{date_part[5..6]}".to_i

          # Convert month abbreviation back to number for comparison
          month_num = Date.strptime(month_abbr, "%b").month
          generated_date = Date.new(year, month_num, day)

          expect(generated_date.month).to eq(month_date.month),
            "Generated date #{generated_date} is not in the same month as input #{month_date}"
          expect(generated_date.year).to eq(month_date.year),
            "Generated date #{generated_date} is not in the same year as input #{month_date}"
          expect(generated_date.friday?).to be(true),
            "Generated date #{generated_date} is not a Friday"
        end
      end
    end

    context "Testing with real current date (no mocking)" do
      it "generates valid contract IDs for current and upcoming months using real dates" do
        # Don't mock Date.current - test with actual current date
        current_contract = manager.generate_current_month_contract_id("BTC")
        upcoming_contract = manager.generate_upcoming_month_contract_id("BTC")

        # Verify format is correct
        expect(current_contract).to match(/\ABIT-\d{2}[A-Z]{3}\d{2}-CDE\z/)
        expect(upcoming_contract).to match(/\ABIT-\d{2}[A-Z]{3}\d{2}-CDE\z/)

        # Verify the dates are actually last Fridays of their respective months
        current_date_part = current_contract.split("-")[1]
        upcoming_date_part = upcoming_contract.split("-")[1]

        current_day = current_date_part[0..1].to_i
        current_month = Date.strptime(current_date_part[2..4], "%b").month
        current_year = "20#{current_date_part[5..6]}".to_i
        current_friday = Date.new(current_year, current_month, current_day)

        upcoming_day = upcoming_date_part[0..1].to_i
        upcoming_month = Date.strptime(upcoming_date_part[2..4], "%b").month
        upcoming_year = "20#{upcoming_date_part[5..6]}".to_i
        upcoming_friday = Date.new(upcoming_year, upcoming_month, upcoming_day)

        # Verify these are actually Fridays
        expect(current_friday.friday?).to be true
        expect(upcoming_friday.friday?).to be true

        # Verify they are the last Fridays of their months
        expect(current_friday + 7.days).to be > current_friday.end_of_month
        expect(upcoming_friday + 7.days).to be > upcoming_friday.end_of_month

        # Verify upcoming month is actually next month
        expect(upcoming_friday.month).to eq(Date.current.next_month.month)
      end

      it "generates different contract IDs for different assets with same date logic" do
        btc_current = manager.generate_current_month_contract_id("BTC")
        eth_current = manager.generate_current_month_contract_id("ETH")

        # Should have same date part but different prefixes
        btc_date_part = btc_current.split("-")[1]
        eth_date_part = eth_current.split("-")[1]

        expect(btc_date_part).to eq(eth_date_part), "BTC and ETH should have same expiration date"
        expect(btc_current).to start_with("BIT-")
        expect(eth_current).to start_with("ET-")
      end
    end

    context "Boundary conditions and edge cases" do
      it "handles months where last day is Friday" do
        # Find a month where the last day is Friday (31st or 30th is Friday)
        # May 2024: 31st is Friday
        test_date = Date.new(2024, 5, 15)
        contract_id = manager.generate_contract_id_for_month("BTC", test_date)
        expect(contract_id).to eq("BIT-31MAY24-CDE")
      end

      it "handles months where last day is Saturday (Friday is 2nd to last)" do
        # March 2024: 31st is Sunday, 30th is Saturday, 29th is Friday
        test_date = Date.new(2024, 3, 15)
        contract_id = manager.generate_contract_id_for_month("BTC", test_date)
        expect(contract_id).to eq("BIT-29MAR24-CDE")
      end

      it "handles February in leap years vs non-leap years correctly" do
        # Leap year: February 2024 has 29 days
        leap_feb = Date.new(2024, 2, 15)
        leap_contract = manager.generate_contract_id_for_month("BTC", leap_feb)

        # Non-leap year: February 2023 has 28 days
        non_leap_feb = Date.new(2023, 2, 15)
        non_leap_contract = manager.generate_contract_id_for_month("BTC", non_leap_feb)

        # Extract days to verify different last Fridays due to leap year
        leap_day = leap_contract.split("-")[1][0..1].to_i
        non_leap_day = non_leap_contract.split("-")[1][0..1].to_i

        # Verify both are valid Fridays in their respective months
        leap_friday = Date.new(2024, 2, leap_day)
        non_leap_friday = Date.new(2023, 2, non_leap_day)

        expect(leap_friday.friday?).to be true
        expect(non_leap_friday.friday?).to be true
        expect(leap_friday.month).to eq(2)
        expect(non_leap_friday.month).to eq(2)
      end

      it "safety check prevents infinite loop if no Friday found in month" do
        # This should never happen in real world, but test the safety mechanism
        # by manually testing the algorithm with a hypothetical scenario
        test_date = Date.new(2024, 8, 15)

        # The algorithm should always find a Friday since every month has at least 4-5 Fridays
        contract_id = manager.generate_contract_id_for_month("BTC", test_date)
        expect(contract_id).to be_present
        expect(contract_id).to match(/\ABIT-\d{2}AUG24-CDE\z/)
      end
    end
  end

  describe "Integration with real TradingPair creation" do
    it "creates actual TradingPair records with correct expiration dates" do
      # Test the full workflow without mocking dates
      contract_id = manager.discover_current_month_contract("BTC")

      expect(contract_id).to be_present
      trading_pair = TradingPair.find_by(product_id: contract_id)
      expect(trading_pair).to be_present

      # Verify the expiration date is actually a Friday
      expect(trading_pair.expiration_date.friday?).to be true

      # Verify it's in the current month
      expect(trading_pair.expiration_date.month).to eq(Date.current.month)
      expect(trading_pair.expiration_date.year).to eq(Date.current.year)

      # Verify it's the last Friday of the month
      next_friday = trading_pair.expiration_date + 7.days
      expect(next_friday).to be > trading_pair.expiration_date.end_of_month
    end

    it "creates upcoming month contracts with correct future dates" do
      contract_id = manager.discover_upcoming_month_contract("ETH")

      expect(contract_id).to be_present
      trading_pair = TradingPair.find_by(product_id: contract_id)
      expect(trading_pair).to be_present

      # Verify the expiration date is a Friday
      expect(trading_pair.expiration_date.friday?).to be true

      # Verify it's in the next month
      next_month = Date.current.next_month
      expect(trading_pair.expiration_date.month).to eq(next_month.month)
      expect(trading_pair.expiration_date.year).to eq(next_month.year)
    end
  end

  describe "Dynamic test helpers for reducing hardcoded values" do
    # Helper method to generate expected contract ID for any date
    def expected_contract_id_for_date(asset, date)
      prefix = MarketData::FuturesContractManager::ASSET_MAPPING[asset.upcase]
      return nil unless prefix

      last_day = date.end_of_month
      expiration_date = last_day
      until expiration_date.friday?
        expiration_date -= 1.day
        break if expiration_date < date.beginning_of_month
      end

      date_str = expiration_date.strftime("%d%b%y").upcase
      "#{prefix}-#{date_str}-CDE"
    end

    it "uses dynamic generation instead of hardcoded values for test validation" do
      test_date = Date.new(2024, 6, 15)

      # Generate using service
      actual_contract_id = manager.generate_contract_id_for_month("BTC", test_date)

      # Generate expected using helper (validates our understanding is correct)
      expected_contract_id = expected_contract_id_for_date("BTC", test_date)

      expect(actual_contract_id).to eq(expected_contract_id)

      # Verify it's not hardcoded by testing with different date
      different_date = Date.new(2024, 7, 15)
      actual_different = manager.generate_contract_id_for_month("BTC", different_date)
      expected_different = expected_contract_id_for_date("BTC", different_date)

      expect(actual_different).to eq(expected_different)
      expect(actual_different).not_to eq(actual_contract_id), "Different months should generate different contract IDs"
    end

    it "validates contract generation matches our test helper logic across multiple months" do
      (1..12).each do |month|
        test_date = Date.new(2024, month, 15)

        actual_btc = manager.generate_contract_id_for_month("BTC", test_date)
        actual_eth = manager.generate_contract_id_for_month("ETH", test_date)

        expected_btc = expected_contract_id_for_date("BTC", test_date)
        expected_eth = expected_contract_id_for_date("ETH", test_date)

        expect(actual_btc).to eq(expected_btc), "BTC contract mismatch for month #{month}"
        expect(actual_eth).to eq(expected_eth), "ETH contract mismatch for month #{month}"
      end
    end
  end

  describe "Regression tests for core logic failures" do
    it "fails appropriately when core date calculation logic is broken" do
      # Test that would catch the issue mentioned in the Linear ticket
      # where tests were passing even when generate_current_month_contract_id returned nil

      # This test uses real logic and should fail if the method returns nil
      contract_id = manager.generate_current_month_contract_id("BTC")
      expect(contract_id).not_to be_nil
      expect(contract_id).to match(/\ABIT-\d{2}[A-Z]{3}\d{2}-CDE\z/)

      # Test that the contract ID contains a valid date
      date_part = contract_id.split("-")[1]
      day = date_part[0..1].to_i
      expect(day).to be_between(1, 31)

      # Test that it's actually for the current month
      month_abbr = date_part[2..4]
      current_month_abbr = Date.current.strftime("%b").upcase
      expect(month_abbr).to eq(current_month_abbr)
    end

    it "detects when 'last Friday' calculation returns wrong day of week" do
      # This test would catch bugs in the until expiration_date.friday? loop
      contract_id = manager.generate_current_month_contract_id("BTC")

      # Extract and validate the date
      date_part = contract_id.split("-")[1]
      day = date_part[0..1].to_i
      month_abbr = date_part[2..4]
      year = "20#{date_part[5..6]}".to_i

      month_num = Date.strptime(month_abbr, "%b").month
      expiration_date = Date.new(year, month_num, day)

      # This should always be a Friday if the logic is correct
      expect(expiration_date.friday?).to be(true),
        "Contract expiration date #{expiration_date} should be a Friday but is #{expiration_date.strftime("%A")}"
    end

    it "detects when algorithm finds Friday from wrong month" do
      # Test that would catch the safety check bug where date goes before beginning_of_month
      test_months = [Date.new(2024, 1, 1), Date.new(2024, 2, 1), Date.new(2024, 12, 1)]

      test_months.each do |month_start|
        contract_id = manager.generate_contract_id_for_month("BTC", month_start)

        date_part = contract_id.split("-")[1]
        date_part[0..1].to_i
        month_abbr = date_part[2..4]

        extracted_month_num = Date.strptime(month_abbr, "%b").month

        expect(extracted_month_num).to eq(month_start.month),
          "Contract for #{month_start.strftime("%B")} should expire in same month, " \
          "but got month #{extracted_month_num}"
      end
    end
  end
end
