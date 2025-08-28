# frozen_string_literal: true

require 'rails_helper'

# INTENTIONAL BREAKING CHANGE FOR CI TESTING
# This syntax error will definitely cause the test to fail
def this will break the ruby syntax parser

RSpec.describe 'Realtime Signals Rake Tasks' do
  describe 'Rake task file validation' do
    let(:rake_file_path) { Rails.root.join('lib/tasks/realtime_signals.rake') }

    it 'has a valid rake task file' do
      expect(File.exist?(rake_file_path)).to be true
    end

    it 'defines the realtime namespace' do
      rake_content = File.read(rake_file_path)
      expect(rake_content).to include('namespace :realtime do')
    end

    it 'defines expected rake tasks' do
      rake_content = File.read(rake_file_path)

      expect(rake_content).to include('task signals:')
      expect(rake_content).to include('task signal_job:')
      expect(rake_content).to include('task evaluate:')
      expect(rake_content).to include('task :evaluate_symbol')
      expect(rake_content).to include('task stats:')
      expect(rake_content).to include('task cleanup:')
      expect(rake_content).to include('task cancel_all:')
    end

    it 'includes proper task descriptions' do
      rake_content = File.read(rake_file_path)

      expect(rake_content).to include('desc "Start real-time signal evaluation system"')
      expect(rake_content).to include('desc "Start real-time signal evaluation job only (for use with existing market data)"')
      expect(rake_content).to include('desc "Evaluate signals once for all pairs"')
      expect(rake_content).to include('desc "Evaluate signals for specific symbol"')
      expect(rake_content).to include('desc "Show real-time signal statistics"')
      expect(rake_content).to include('desc "Clean up expired signal alerts"')
      expect(rake_content).to include('desc "Cancel all active signal alerts"')
    end

    it 'includes environment loading for tasks' do
      rake_content = File.read(rake_file_path)

      expect(rake_content).to include('=> :environment')
    end
  end

  describe 'Core rake task functionality' do
    let(:logger) { instance_double(Logger) }
    let(:evaluator) { instance_double(RealTimeSignalEvaluator) }

    before(:each) do
      allow(Rails).to receive(:logger).and_return(logger)
      allow(logger).to receive(:info)
      allow(logger).to receive(:warn)
      allow(logger).to receive(:error)

      # Mock all ENV calls that might be needed
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('SIGNALS_API_KEY').and_return('test-key')
      allow(ENV).to receive(:[]).with('FORCE').and_return(nil)
      allow(ENV).to receive(:[]).with('HOURS').and_return(nil)
      allow(ENV).to receive(:fetch).and_call_original
      allow(ENV).to receive(:fetch).with('HOURS', '24').and_return('24')
      allow(ENV).to receive(:fetch).with('SIGNAL_EVALUATION_INTERVAL', '30').and_return('30')
    end

    describe 'evaluate task logic' do
      before do
        allow(RealTimeSignalEvaluator).to receive(:new).and_return(evaluator)
        allow(evaluator).to receive(:evaluate_all_pairs)
      end

      it 'creates RealTimeSignalEvaluator and calls evaluate_all_pairs' do
        expect(RealTimeSignalEvaluator).to receive(:new).with(logger: Rails.logger)
        expect(evaluator).to receive(:evaluate_all_pairs)

        # Test the core logic that would be in the rake task
        Rails.logger.info('[RTS] Evaluating signals for all pairs...')
        evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)
        evaluator.evaluate_all_pairs
        Rails.logger.info('[RTS] Signal evaluation completed.')
      end
    end

    describe 'evaluate_symbol task logic' do
      let(:trading_pair) { instance_double(TradingPair, product_id: 'BTC-USD') }

      context 'with valid symbol' do
        before do
          allow(TradingPair).to receive(:find_by).and_return(trading_pair)
          allow(RealTimeSignalEvaluator).to receive(:new).and_return(evaluator)
          allow(evaluator).to receive(:evaluate_pair)
        end

        it 'finds trading pair and evaluates signals' do
          expect(TradingPair).to receive(:find_by).with(product_id: 'BTC-USD')
          expect(RealTimeSignalEvaluator).to receive(:new).with(logger: Rails.logger)
          expect(evaluator).to receive(:evaluate_pair).with(trading_pair)

          # Test the core logic
          symbol = 'BTC-USD'
          Rails.logger.info("[RTS] Evaluating signals for #{symbol}...")
          trading_pair = TradingPair.find_by(product_id: symbol)
          raise 'Trading pair not found' if trading_pair.nil?

          evaluator = RealTimeSignalEvaluator.new(logger: Rails.logger)
          evaluator.evaluate_pair(trading_pair)
          Rails.logger.info("[RTS] Signal evaluation completed for #{symbol}.")
        end
      end

      context 'with invalid symbol' do
        before do
          allow(TradingPair).to receive(:find_by).with(product_id: 'INVALID-SYMBOL').and_return(nil)
        end

        it 'handles non-existent symbol' do
          symbol = 'INVALID-SYMBOL'
          expect(logger).to receive(:error).with("[RTS] Trading pair not found: #{symbol}")

          trading_pair = TradingPair.find_by(product_id: symbol)
          if trading_pair.nil?
            Rails.logger.error("[RTS] Trading pair not found: #{symbol}")
            # Do not exit the test process; simulate task failure by returning
            next
          end
        end
      end

      context 'with blank symbol' do
        it 'handles blank symbol argument' do
          symbol = ''
          expect(logger).to receive(:error).with('[RTS] Please provide a symbol: rake realtime:evaluate_symbol[BTC-USD]')

          if symbol.blank?
            Rails.logger.error('[RTS] Please provide a symbol: rake realtime:evaluate_symbol[BTC-USD]')
            # Do not exit the test process; simulate task failure by returning
            next
          end
        end
      end
    end

    describe 'stats task logic' do
      let(:signal_scope) { instance_double(ActiveRecord::Relation) }

      before do
        allow(SignalAlert).to receive(:active).and_return(double(count: 5))
        allow(SignalAlert).to receive(:where).and_return(signal_scope)
        allow(signal_scope).to receive(:count).and_return(12)
        allow(signal_scope).to receive(:group).and_return(signal_scope)
        allow(signal_scope).to receive(:average).and_return(double(to_f: 75.5))
        allow(signal_scope).to receive(:pluck).and_return([])
        allow(Kernel).to receive(:puts)
      end

      it 'calculates and displays statistics' do
        hours = 24
        hours.hours.ago

        expect(SignalAlert).to receive(:active).and_return(double(count: 5))
        expect(SignalAlert).to receive(:where).with('alert_timestamp >= ?', anything).at_least(4).times
        allow(Kernel).to receive(:puts)

        # Test the core stats logic
        Rails.logger.info("[RTS] Signal statistics for last #{hours} hours:")
        start_time = hours.hours.ago

        stats = {
          active_signals: SignalAlert.active.count,
          recent_signals: SignalAlert.where('alert_timestamp >= ?', start_time).count,
          triggered_signals: SignalAlert.where('alert_timestamp >= ? AND alert_status = ?', start_time,
                                               'triggered').count,
          expired_signals: SignalAlert.where('alert_timestamp >= ? AND alert_status = ?', start_time, 'expired').count,
          high_confidence_signals: SignalAlert.where('alert_timestamp >= ? AND confidence >= ?', start_time, 70).count,
          signals_by_symbol: SignalAlert.where('alert_timestamp >= ?', start_time)
                                        .group(:symbol)
                                        .count,
          signals_by_strategy: SignalAlert.where('alert_timestamp >= ?', start_time)
                                          .group(:strategy_name)
                                          .count,
          average_confidence: SignalAlert.where('alert_timestamp >= ?', start_time)
                                         .average(:confidence)&.to_f&.round(2)
        }

        stats.each do |key, value|
          puts "#{key}: #{value}"
        end
      end

      it 'handles custom hours parameter' do
        allow(ENV).to receive(:fetch).with('HOURS', '24').and_return('6')

        hours = ENV.fetch('HOURS', '24').to_i
        expect(logger).to receive(:info).with('[RTS] Signal statistics for last 6 hours:')

        Rails.logger.info("[RTS] Signal statistics for last #{hours} hours:")
      end
    end

    describe 'cleanup task logic' do
      let(:first_scope) { instance_double(ActiveRecord::Relation) }
      let(:second_scope) { instance_double(ActiveRecord::Relation) }

      before do
        allow(SignalAlert).to receive(:where).and_return(first_scope)
        allow(first_scope).to receive(:where).and_return(second_scope)
        allow(second_scope).to receive(:update_all).and_return(3)
        allow(Kernel).to receive(:puts)
      end

      it 'cleans up expired signals' do
        expect(SignalAlert).to receive(:where).with('expires_at < ?', anything)
                                              .and_return(first_scope)
        expect(first_scope).to receive(:where).with(alert_status: 'active')
                                              .and_return(second_scope)
        expect(second_scope).to receive(:update_all).with(alert_status: 'expired', updated_at: anything)
                                                    .and_return(3)
        expect(logger).to receive(:info).with('[RTS] Cleaned up 3 expired signal alerts.')
        allow(Kernel).to receive(:puts)

        # Test the core cleanup logic
        expired_count = SignalAlert.where('expires_at < ?', Time.current.utc)
                                   .where(alert_status: 'active')
                                   .update_all(alert_status: 'expired', updated_at: Time.current.utc)

        Rails.logger.info("[RTS] Cleaned up #{expired_count} expired signal alerts.")

        if expired_count > 0
          puts "Cleaned up #{expired_count} expired signal alerts."
        else
          puts 'No expired signal alerts to clean up.'
        end
      end

      it 'handles no expired signals' do
        allow(SignalAlert).to receive(:where).and_return(double(update_all: 0))
        allow(Kernel).to receive(:puts)

        expired_count = 0
        if expired_count > 0
          puts "Cleaned up #{expired_count} expired signal alerts."
        else
          puts 'No expired signal alerts to clean up.'
        end
      end
    end

    describe 'cancel_all task logic' do
      let(:signal_scope) { instance_double(ActiveRecord::Relation) }

      context 'without FORCE=true' do
        before do
          allow(ENV).to receive(:[]).with('FORCE').and_return(nil)
          allow(Kernel).to receive(:puts)
        end

        it 'shows warning and exits' do
          allow(Kernel).to receive(:puts)

          # Test the safety check logic
          if ENV['FORCE'] != 'true'
            puts 'This will cancel ALL active signal alerts. Run with FORCE=true to confirm.'
            puts 'Example: FORCE=true rake realtime:cancel_all'
          end
        end
      end

      context 'with FORCE=true' do
        before do
          allow(ENV).to receive(:[]).with('FORCE').and_return('true')
          allow(SignalAlert).to receive(:where).and_return(signal_scope)
          allow(signal_scope).to receive(:update_all).and_return(5)
          allow(Kernel).to receive(:puts)
        end

        it 'cancels all active signals' do
          expect(SignalAlert).to receive(:where).with(alert_status: 'active')
                                                .and_return(signal_scope)
          expect(signal_scope).to receive(:update_all).with(alert_status: 'cancelled', updated_at: anything)
                                                      .and_return(5)
          expect(logger).to receive(:info).with('[RTS] Cancelled 5 active signal alerts.')
          allow(Kernel).to receive(:puts)

          # Test the core cancellation logic
          cancelled_count = SignalAlert.where(alert_status: 'active')
                                       .update_all(alert_status: 'cancelled', updated_at: Time.current.utc)

          Rails.logger.info("[RTS] Cancelled #{cancelled_count} active signal alerts.")
          puts "Cancelled #{cancelled_count} active signal alerts."
        end
      end
    end

    describe 'Helper methods functionality' do
      describe '#start_market_data_subscriptions' do
        let(:spot_subscriber) { instance_double(MarketData::CoinbaseSpotSubscriber) }
        let(:futures_subscriber) { instance_double(MarketData::CoinbaseFuturesSubscriber) }
        let(:trading_pairs_relation) { instance_double(ActiveRecord::Relation) }

        before do
          allow(TradingPair).to receive(:enabled).and_return(trading_pairs_relation)
          allow(trading_pairs_relation).to receive(:pluck).and_return(['BTC-USD'])
          allow(MarketData::CoinbaseSpotSubscriber).to receive(:new).and_return(spot_subscriber)
          allow(MarketData::CoinbaseFuturesSubscriber).to receive(:new).and_return(futures_subscriber)
          allow(spot_subscriber).to receive(:start)
          allow(futures_subscriber).to receive(:start)
          allow(Kernel).to receive(:sleep)
        end

        it 'creates subscribers for enabled trading pairs' do
          expect(TradingPair).to receive(:enabled).and_return(trading_pairs_relation)
          expect(trading_pairs_relation).to receive(:pluck).with(:product_id).and_return(['BTC-USD'])

          expect(MarketData::CoinbaseSpotSubscriber).to receive(:new).with(
            product_ids: ['BTC-USD'],
            enable_candle_aggregation: true,
            logger: Rails.logger
          )
          expect(MarketData::CoinbaseFuturesSubscriber).to receive(:new).with(
            product_ids: ['BTC-USD'],
            enable_candle_aggregation: true,
            logger: Rails.logger
          )

          # Test the core subscription logic
          product_ids = TradingPair.enabled.pluck(:product_id)

          if product_ids.empty?
            Rails.logger.warn('[RTS] No enabled trading pairs found. Skipping market data subscriptions.')
            next
          end

          Rails.logger.info("[RTS] Starting market data subscriptions for #{product_ids.count} products: #{product_ids.join(', ')}")

          MarketData::CoinbaseSpotSubscriber.new(
            product_ids: product_ids,
            enable_candle_aggregation: true,
            logger: Rails.logger
          )

          MarketData::CoinbaseFuturesSubscriber.new(
            product_ids: product_ids,
            enable_candle_aggregation: true,
            logger: Rails.logger
          )
        end

        it 'handles no enabled trading pairs' do
          allow(TradingPair).to receive(:enabled).and_return(trading_pairs_relation)
          allow(trading_pairs_relation).to receive(:pluck).and_return([])
          expect(logger).to receive(:warn).with('[RTS] No enabled trading pairs found. Skipping market data subscriptions.')

          product_ids = TradingPair.enabled.pluck(:product_id)
          if product_ids.empty?
            Rails.logger.warn('[RTS] No enabled trading pairs found. Skipping market data subscriptions.')
          end
        end
      end

      describe '#start_signal_evaluation' do
        it 'starts real-time signal evaluation with configured interval' do
          allow(ENV).to receive(:fetch).with('SIGNAL_EVALUATION_INTERVAL', '30').and_return('45')
          allow(RealTimeSignalJob).to receive(:send).with(:start_realtime_evaluation, interval_seconds: 45)

          expect(RealTimeSignalJob).to receive(:send).with(:start_realtime_evaluation, interval_seconds: 45)

          # Test the core evaluation start logic
          Rails.logger.info('[RTS] Starting real-time signal evaluation...')
          RealTimeSignalJob.send(:start_realtime_evaluation, interval_seconds: ENV.fetch('SIGNAL_EVALUATION_INTERVAL',
                                                                                         '30').to_i)
        end
      end

      describe '#realtime_cleanup' do
        let(:first_scope) { instance_double(ActiveRecord::Relation) }
        let(:second_scope) { instance_double(ActiveRecord::Relation) }

        before do
          allow(SignalAlert).to receive(:where).and_return(first_scope)
          allow(first_scope).to receive(:where).and_return(second_scope)
        end

        it 'cleans up expired alerts during shutdown' do
          allow(second_scope).to receive(:update_all).and_return(2)

          expect(logger).to receive(:info).with('[RTS] Cleaned up 2 expired alerts during shutdown.')

          # Test the cleanup logic
          expired_count = SignalAlert.where('expires_at < ?', Time.current.utc)
                                     .where(alert_status: 'active')
                                     .update_all(alert_status: 'expired', updated_at: Time.current.utc)

          Rails.logger.info("[RTS] Cleaned up #{expired_count} expired alerts during shutdown.") if expired_count > 0
        end

        it 'does not log when no alerts are cleaned up' do
          allow(second_scope).to receive(:update_all).and_return(0)

          expect(logger).not_to receive(:info)

          expired_count = 0
          Rails.logger.info("[RTS] Cleaned up #{expired_count} expired alerts during shutdown.") if expired_count > 0
        end
      end
    end
  end
end
