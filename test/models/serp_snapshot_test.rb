require "test_helper"

class SerpSnapshotTest < ActiveSupport::TestCase
  test "fresh_for returns a recent snapshot and ignores a stale one" do
    stale = SerpSnapshot.create!(query: "french worksheets pdf", engine: "google",
                                 payload: { "organic_results" => [] }, fetched_at: 2.days.ago)

    assert_not stale.fresh?
    assert_nil SerpSnapshot.fresh_for(query: "french worksheets pdf")
    # Stale is still readable, so the page can show last week's rank for free.
    assert_equal stale, SerpSnapshot.latest_for(query: "french worksheets pdf")

    fresh = SerpSnapshot.record!(query: "french worksheets pdf", engine: "google", payload: { "organic_results" => [] })
    assert fresh.fresh?
    assert_equal fresh, SerpSnapshot.fresh_for(query: "french worksheets pdf")
  end

  test "snapshots are scoped per engine" do
    SerpSnapshot.record!(query: "french worksheets pdf", engine: "google", payload: {})

    assert_nil SerpSnapshot.fresh_for(query: "french worksheets pdf", engine: "google_shopping")
    assert_not_nil SerpSnapshot.fresh_for(query: "french worksheets pdf", engine: "google")
  end

  test "latest_for returns the newest row for a query" do
    SerpSnapshot.create!(query: "q", engine: "google", payload: { "n" => 1 }, fetched_at: 3.hours.ago)
    newest = SerpSnapshot.create!(query: "q", engine: "google", payload: { "n" => 2 }, fetched_at: 1.hour.ago)

    assert_equal newest, SerpSnapshot.latest_for(query: "q")
  end
end
