require "test_helper"

class DemandGapAnalyzerTest < ActiveSupport::TestCase
  # Demand side: two cached searches. "verb conjugation" shows up in both,
  # "numbers 1 to 100" in one, and the catalogue covers neither by default.
  def snapshot(payload)
    SerpSnapshot.new(query: "french worksheets pdf", engine: "google", payload: payload, fetched_at: Time.current)
  end

  def demand_payload
    {
      "related_searches" => [
        { "query" => "French verb conjugation worksheet PDF" },
        { "query" => "french numbers 1 to 100 worksheet" }
      ],
      "related_questions" => [
        { "question" => "How do you practise French verb conjugation?" }
      ]
    }
  end

  test "reports demand the catalogue does not cover, most-mentioned first" do
    result = DemandGapAnalyzer.new(
      products:   [],
      snapshots:  [snapshot(demand_payload)],
      units_sold: {}
    ).call

    phrases = result[:gaps].map(&:phrase)
    assert_includes phrases, "french verb conjugation worksheet pdf"
    assert_includes phrases, "french numbers 1 to 100 worksheet"

    # The related search and the question are the SAME topic in two phrasings,
    # so they cluster into one gap with two mentions and outrank the single.
    assert_equal "french verb conjugation worksheet pdf", phrases.first
    assert_equal 2, result[:gaps].first.mentions
    assert_equal 2, result[:gaps].size
  end

  test "a phrase the catalogue already covers is not reported as a gap" do
    product = Product.new(id: 1, title: "Verb Conjugation Drills", description: "Practice conjugating French verbs.")

    result = DemandGapAnalyzer.new(
      products:   [product],
      snapshots:  [snapshot(demand_payload)],
      units_sold: { 1 => 3 }
    ).call

    assert_not_includes result[:gaps].map(&:phrase), "french verb conjugation worksheet pdf"
    assert_includes result[:gaps].map(&:phrase), "french numbers 1 to 100 worksheet"
  end

  test "a more specific phrasing folds into the general topic it belongs to" do
    payload = { "related_searches" => [{ "query" => "french numbers to 100 worksheet" }],
                "related_questions" => [{ "question" => "How do you teach French numbers to 100?" }] }

    gaps = DemandGapAnalyzer.new(products: [], snapshots: [snapshot(payload)], units_sold: {}).call[:gaps]

    assert_equal 1, gaps.size
    assert_equal 2, gaps.first.mentions
    # The non-question phrasing wins the label, because it is what a worksheet
    # would be called.
    assert_equal "french numbers to 100 worksheet", gaps.first.phrase
  end

  # Numbers and CEFR levels are shorter than the noise cutoff but carry all the
  # meaning: "grade 3" and "grade 4" are different worksheets, and an A1 pack is
  # not a B2 pack. Dropping them collapsed every grade into one topic labelled
  # by whichever phrasing happened to sort first.
  test "grades and CEFR levels are separate topics, not one merged blob" do
    payload = { "related_queries" => { "top" => [
      { "query" => "french worksheets grade 3", "value" => 90 },
      { "query" => "grade 4 french worksheets", "value" => 80 },
      { "query" => "french worksheets a1",      "value" => 70 },
      { "query" => "french worksheets b2",      "value" => 60 }
    ] } }

    gaps = DemandGapAnalyzer.new(products: [], snapshots: [snapshot(payload)], units_sold: {}).call[:gaps]

    assert_equal 4, gaps.size
    assert_equal [90, 80, 70, 60], gaps.map(&:score)
    assert_includes gaps.map(&:phrase), "french worksheets grade 3"
    assert_includes gaps.map(&:phrase), "grade 4 french worksheets"
    assert_includes gaps.map(&:phrase), "french worksheets a1"
  end

  test "a level-specific worksheet only covers its own level" do
    a1_pack = Product.new(id: 1, title: "A1 Grammar practice pack", description: "Grammar drills.")

    payload = { "related_queries" => { "top" => [
      { "query" => "french grammar a1", "value" => 90 },
      { "query" => "french grammar b2", "value" => 80 }
    ] } }

    gaps = DemandGapAnalyzer.new(products: [a1_pack], snapshots: [snapshot(payload)], units_sold: { 1 => 4 }).call[:gaps]

    assert_equal ["french grammar b2"], gaps.map(&:phrase)
  end

  # Google Trends drifts: seeded with "french grammar" it returns french toast
  # and calligraphy. And some real French demand is for a different product.
  test "drops demand that is off-topic or wants a different product" do
    payload = { "related_queries" => { "top" => [
      { "query" => "french toast near me",        "value" => 100 },
      { "query" => "how to learn calligraphy",    "value" => 90 },
      { "query" => "best french app",             "value" => 80 },
      { "query" => "french tutor near me",        "value" => 70 },
      { "query" => "french grammar for beginners", "value" => 60 }
    ] } }

    gaps = DemandGapAnalyzer.new(products: [], snapshots: [snapshot(payload)], units_sold: {}).call[:gaps]

    assert_equal ["french grammar for beginners"], gaps.map(&:phrase)
  end

  test "flags searches that want the worksheet for free" do
    payload = { "related_searches" => [{ "query" => "free french worksheets for beginners" }] }

    gap = DemandGapAnalyzer.new(products: [], snapshots: [snapshot(payload)], units_sold: {}).call[:gaps].first

    assert gap.free_intent
  end

  # ---- the join that matters: demand x sales -------------------------------

  test "verdicts separate proven sellers from wanted-but-not-selling" do
    selling   = Product.new(id: 1, title: "Verb Conjugation Drills", description: "Conjugating French verbs.")
    unwanted  = Product.new(id: 2, title: "Medieval Occitan Poetry", description: "Old poems.")
    ignored   = Product.new(id: 3, title: "French Numbers 1 to 100", description: "Numbers practice.")

    result = DemandGapAnalyzer.new(
      products:   [selling, unwanted, ignored],
      snapshots:  [snapshot(demand_payload)],
      units_sold: { 1 => 5, 2 => 2 }
    ).call

    verdicts = result[:catalogue].to_h { |row| [row.product.id, row.verdict] }

    assert_equal :proven,          verdicts[1]  # searched for AND sold
    assert_equal :selling_quietly, verdicts[2]  # sold, but nobody searches it
    assert_equal :undiscovered,    verdicts[3]  # searched for, never sold — fix the listing
  end

  test "counts paid units from both the cart and legacy single-product orders" do
    product = products(:one)

    paid = Order.create!(email: "a@example.com", name: "A", status: "paid",
                         payment_provider: "razorpay", currency: "INR", amount_cents: 100)
    OrderItem.create!(order: paid, product: product, unit_amount_cents: 100)

    # A legacy order carries the product directly, with no order_items row.
    Order.create!(email: "b@example.com", name: "B", status: "paid", product: product,
                  payment_provider: "razorpay", currency: "INR", amount_cents: 100)

    # An unpaid order must not count.
    Order.create!(email: "c@example.com", name: "C", status: "pending", product: product,
                  payment_provider: "razorpay", currency: "INR", amount_cents: 100)

    counted = DemandGapAnalyzer.paid_units_by_product[product.id]
    assert_equal 2, counted
  end

  test "handles an empty cache without raising" do
    result = DemandGapAnalyzer.new(products: [], snapshots: [], units_sold: {}).call

    assert_empty result[:gaps]
    assert_equal 0, result[:searches_mined]
  end
end
