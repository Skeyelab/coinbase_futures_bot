# frozen_string_literal: true

require "rails_helper"

RSpec.describe SentryDatabaseMonitoring do
  subject(:middleware) { described_class.new }

  # ActiveRecord usually hands us QueryAttribute objects, but not always: a
  # LIKE built from a raw string arrives as a bare String, and some callers
  # pass Time values straight through.
  let(:query_attribute) { instance_double(ActiveRecord::Relation::QueryAttribute, value: "BTC-PERP") }

  let(:captured) { [] }

  before do
    allow(SentryHelper).to receive(:add_breadcrumb)
    allow(Sentry).to receive(:capture_message)
    allow(Sentry).to receive(:capture_exception)

    scope = instance_double(Sentry::Scope)
    allow(scope).to receive(:set_tag)
    allow(scope).to receive(:set_context) { |name, data| captured << [name, data] }
    allow(Sentry).to receive(:with_scope).and_yield(scope)
  end

  # Anything over the 1000ms default threshold counts as slow.
  def report_slow_query(binds:, sql: "SELECT * FROM products WHERE symbol LIKE $1")
    middleware.call("sql.active_record", 0.0, 2.0, "uid", {sql: sql, binds: binds})
  end

  describe "slow query reporting" do
    it "records bind values that arrive as plain strings" do
      expect { report_slow_query(binds: ["NOL%"]) }.not_to raise_error

      _name, context = captured.last
      expect(context[:binds]).to eq(["NOL%"])
    end

    it "still unwraps ordinary query attributes" do
      report_slow_query(binds: [query_attribute])

      _name, context = captured.last
      expect(context[:binds]).to eq(["BTC-PERP"])
    end

    it "handles a mix of wrapped and bare binds in one query" do
      report_slow_query(binds: [query_attribute, "NOL%"])

      _name, context = captured.last
      expect(context[:binds]).to eq(["BTC-PERP", "NOL%"])
    end

    # The other shape seen in production logs.
    it "records a bare time bind without raising" do
      moment = Time.zone.parse("2026-07-28 02:00:00")

      expect { report_slow_query(binds: [moment]) }.not_to raise_error

      _name, context = captured.last
      expect(context[:binds]).to eq([moment])
    end

    it "caps how many bind values it ships" do
      report_slow_query(binds: Array.new(25) { |i| "bind-#{i}" })

      _name, context = captured.last
      expect(context[:binds].size).to eq(10)
      expect(context[:binds].first).to eq("bind-0")
    end

    it "copes with a query that reports no binds at all" do
      expect { report_slow_query(binds: nil) }.not_to raise_error

      _name, context = captured.last
      expect(context[:binds]).to be_nil
    end
  end

  describe "failed query reporting" do
    def report_failed_query(binds:)
      middleware.call("sql.active_record", 0.0, 0.001, "uid", {
        sql: "SELECT * FROM products WHERE symbol LIKE $1",
        binds: binds,
        exception: ["ActiveRecord::StatementInvalid", "boom"]
      })
    end

    # The same unsafe unwrap existed on the error path, where it would have
    # masked the very failure Sentry was being told about.
    it "records bare string binds on a failed query" do
      expect { report_failed_query(binds: ["NOL%"]) }.not_to raise_error

      _name, context = captured.last
      expect(context[:binds]).to eq(["NOL%"])
    end
  end
end
