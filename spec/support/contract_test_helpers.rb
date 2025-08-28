# frozen_string_literal: true

module ContractTestHelpers
  # Dynamically generates expected contract ID for any asset and date
  # This reduces hardcoded values in tests and ensures consistency
  def generate_expected_contract_id(asset, month_date)
    prefix = MarketData::FuturesContractManager::ASSET_MAPPING[asset.upcase]
    return nil unless prefix

    # Find the last Friday of the specified month (matches production logic)
    last_day = month_date.end_of_month
    expiration_date = last_day
    until expiration_date.friday?
      expiration_date -= 1.day
      # Safety check - don't go before the start of the month
      break if expiration_date < month_date.beginning_of_month
    end

    # Format as DDMMMYY (e.g., 29AUG25)
    date_str = expiration_date.strftime("%d%b%y").upcase
    "#{prefix}-#{date_str}-CDE"
  end

  # Creates a TradingPair with dynamically generated contract ID
  def create_trading_pair_for_month(asset, month_date, **options)
    contract_id = generate_expected_contract_id(asset, month_date)
    expiration_date = extract_expiration_date_from_contract_id(contract_id)

    TradingPair.create!({
      product_id: contract_id,
      base_currency: asset.upcase,
      quote_currency: "USD",
      expiration_date: expiration_date,
      contract_type: "CDE",
      enabled: true,
      status: "online"
    }.merge(options))
  end

  # Extracts the actual expiration date from a contract ID
  def extract_expiration_date_from_contract_id(contract_id)
    return nil unless contract_id

    # Extract date part from format: PREFIX-DDMMMYY-CDE
    date_part = contract_id.split("-")[1]
    return nil unless date_part&.length == 7

    day = date_part[0..1].to_i
    month_abbr = date_part[2..4]
    year = "20#{date_part[5..6]}".to_i

    month_num = Date.strptime(month_abbr, "%b").month
    Date.new(year, month_num, day)
  rescue ArgumentError
    nil
  end

  # Validates that a contract ID follows the correct format and represents a Friday
  def validate_contract_id_format(contract_id, expected_asset: nil, expected_month: nil)
    expect(contract_id).to match(/\A(BIT|ET)-\d{2}[A-Z]{3}\d{2}-CDE\z/),
      "Contract ID #{contract_id} should match expected format"

    # Extract components
    parts = contract_id.split("-")
    prefix = parts[0]
    parts[1]
    suffix = parts[2]

    expect(suffix).to eq("CDE"), "Contract should end with CDE"

    if expected_asset
      expected_prefix = MarketData::FuturesContractManager::ASSET_MAPPING[expected_asset.upcase]
      expect(prefix).to eq(expected_prefix),
        "Prefix should be #{expected_prefix} for asset #{expected_asset}"
    end

    # Validate the date represents a Friday
    expiration_date = extract_expiration_date_from_contract_id(contract_id)
    expect(expiration_date).to be_present, "Should be able to parse expiration date"
    expect(expiration_date.friday?).to be true,
      "Expiration date #{expiration_date} should be a Friday"

    if expected_month
      expect(expiration_date.month).to eq(expected_month.month),
        "Contract should be for month #{expected_month.month}"
      expect(expiration_date.year).to eq(expected_month.year),
        "Contract should be for year #{expected_month.year}"
    end

    expiration_date
  end

  # Creates a complete set of test contracts for current and upcoming months
  def create_test_contract_set(assets: %w[BTC ETH], reference_date: Date.current)
    contracts = {}

    assets.each do |asset|
      # Current month contract
      current_contract = create_trading_pair_for_month(asset, reference_date)
      contracts["#{asset.downcase}_current"] = current_contract

      # Upcoming month contract
      upcoming_contract = create_trading_pair_for_month(asset, reference_date.next_month)
      contracts["#{asset.downcase}_upcoming"] = upcoming_contract
    end

    contracts
  end

  # Verifies that a contract is properly configured for trading
  def verify_trading_contract(trading_pair, expected_asset:, expected_expiration_month:)
    expect(trading_pair).to be_present
    expect(trading_pair.base_currency).to eq(expected_asset.upcase)
    expect(trading_pair.quote_currency).to eq("USD")
    expect(trading_pair.contract_type).to eq("CDE")
    expect(trading_pair.enabled).to be true

    # Verify expiration date is a Friday in the expected month
    expect(trading_pair.expiration_date.friday?).to be true
    expect(trading_pair.expiration_date.month).to eq(expected_expiration_month.month)
    expect(trading_pair.expiration_date.year).to eq(expected_expiration_month.year)

    # Verify it's the last Friday of the month
    next_friday = trading_pair.expiration_date + 7.days
    expect(next_friday).to be > trading_pair.expiration_date.end_of_month
  end

  # Test edge cases for last Friday calculation
  def test_last_friday_edge_cases
    [
      # Month where last day is Friday (May 2024: 31st is Friday)
      {date: Date.new(2024, 5, 15), expected_last_friday: Date.new(2024, 5, 31)},
      # Month where last day is Saturday (March 2024: 31st is Sunday, 29th is Friday)
      {date: Date.new(2024, 3, 15), expected_last_friday: Date.new(2024, 3, 29)},
      # February in leap year
      {date: Date.new(2024, 2, 15), expected_last_friday: Date.new(2024, 2, 23)},
      # February in non-leap year
      {date: Date.new(2023, 2, 15), expected_last_friday: Date.new(2023, 2, 24)},
      # Month with first day as Friday (ensure we get LAST Friday)
      {date: Date.new(2024, 3, 10), expected_last_friday: Date.new(2024, 3, 29)}
    ]
  end
end

# Include in RSpec configuration
RSpec.configure do |config|
  config.include ContractTestHelpers
end
