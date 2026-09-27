require "test_helper"

class Admin::MarketIntelligenceControllerTest < ActionDispatch::IntegrationTest
  KEYWORD = Admin::MarketIntelligenceController::TRACKED_KEYWORDS.first

  SEARCH_PAYLOAD = {
    "organic_results" => [
      { "position" => 1, "title" => "Other site",     "link" => "https://example.com/french" },
      { "position" => 2, "title" => "Worksheet Hub",  "link" => "https://frenchworksheethub.com/worksheets" }
    ],
    "related_questions" => [{ "question" => "How do you conjugate avoir?", "snippet" => "Avoir is irregular." }],
    "related_searches"  => [{ "query" => "french avoir worksheet" }]
  }.freeze

  # ---- auth guard ----------------------------------------------------------

  test "redirects to login when signed out" do
    get admin_market_intelligence_path
    assert_redirected_to admin_login_path
  end

  test "refresh redirects to login when signed out and spends no search" do
    assert_no_difference "SerpSnapshot.count" do
      post admin_refresh_market_intelligence_path
    end
    assert_redirected_to admin_login_path
  end

  # ---- index ---------------------------------------------------------------

  test "renders with no cached snapshots and no API key, without calling SerpApi" do
    sign_in_admin
    SerpApiClient.stub(:api_key, nil) do
      get admin_market_intelligence_path
    end

    assert_response :success
    assert_select "h1", /Research/
    assert_match "SerpApi isn't set up yet", response.body
  end

  test "shows our rank and competitors from a cached snapshot" do
    SerpSnapshot.record!(query: KEYWORD, engine: "google", payload: SEARCH_PAYLOAD)

    sign_in_admin
    get admin_market_intelligence_path

    assert_response :success
    assert_match "#2", response.body              # our position
    assert_match "example.com", response.body     # a competitor
  end

  test "shows cached competitor pricing with a median" do
    SerpSnapshot.record!(
      query:   Admin::MarketIntelligenceController::PRICING_QUERY,
      engine:  Admin::MarketIntelligenceController::PRICING_ENGINE,
      payload: { "shopping_results" => [
        { "title" => "French Workbook A1", "price" => "$4.00", "extracted_price" => 4.0,  "source" => "Etsy" },
        { "title" => "Conjugation Pack",   "price" => "$9.00", "extracted_price" => 9.0,  "source" => "TPT" },
        { "title" => "Grammar Bundle",     "price" => "$12.00", "extracted_price" => 12.0, "source" => "Gumroad" }
      ] }
    )

    sign_in_admin
    get admin_market_intelligence_path

    assert_response :success
    assert_match "French Workbook A1", response.body
    assert_match "Etsy", response.body
    assert_match "Median listed price", response.body
    assert_match ">9<", response.body   # median of 4 / 9 / 12
  end

  test "demand gap card lists uncovered demand and joins sales onto the catalogue" do
    product = Product.create!(title: "Avoir Conjugation Drills", slug: "avoir-conjugation-drills",
                              price_in_paise: 9900, active: true)

    paid = Order.create!(email: "a@example.com", name: "A", status: "paid",
                         payment_provider: "razorpay", currency: "INR", amount_cents: 100)
    OrderItem.create!(order: paid, product: product, unit_amount_cents: 100)

    SerpSnapshot.record!(query: KEYWORD, engine: "google", payload: {
      "related_searches"  => [{ "query" => "french avoir conjugation drills" },
                              { "query" => "french numbers to 100 worksheet" }],
      "related_questions" => [{ "question" => "How do you teach French numbers to 100?" }]
    })

    sign_in_admin
    get admin_market_intelligence_path

    assert_response :success
    # Demand with no matching worksheet → a gap, clustered across both phrasings.
    assert_match "french numbers to 100 worksheet", response.body
    assert_match "2 signals", response.body
    # Demand she already covers AND has sold → proven, not a gap.
    assert_match "Avoir Conjugation Drills", response.body
    assert_match "Proven", response.body
  end

  test "demand gap card is empty and costs nothing before anything is cached" do
    sign_in_admin
    get admin_market_intelligence_path

    assert_response :success
    assert_match "Nothing mined yet", response.body
  end

  test "topic form triggers one live search and lists the questions it found" do
    sign_in_admin

    calls = []
    search = lambda do |query:, **opts|
      calls << [query, opts[:engine]]
      SEARCH_PAYLOAD
    end

    SerpApiClient.stub(:api_key, "test-key") do
      SerpApiClient.stub(:search, search) do
        get admin_market_intelligence_path(topic: "french verb conjugation")
      end
    end

    assert_response :success
    assert_equal [["french verb conjugation", "google"]], calls
    assert_match "How do you conjugate avoir?", response.body
    assert_match "french avoir worksheet", response.body
    # On-demand only: the topic lookup is never written to the snapshot cache.
    assert_nil SerpSnapshot.latest_for(query: "french verb conjugation")
  end

  test "a SerpApi failure on the topic form shows a message instead of blowing up" do
    sign_in_admin

    failing = ->(**_opts) { raise SerpApiClient::Error, "quota exhausted" }

    SerpApiClient.stub(:api_key, "test-key") do
      SerpApiClient.stub(:search, failing) do
        get admin_market_intelligence_path(topic: "french verb conjugation")
      end
    end

    assert_response :success
    assert_match "quota exhausted", response.body
  end

  # ---- refresh -------------------------------------------------------------

  test "refreshing ranks caches one snapshot per tracked keyword plus pricing" do
    sign_in_admin

    expected = Admin::MarketIntelligenceController::TRACKED_KEYWORDS.size + 1

    SerpApiClient.stub(:api_key, "test-key") do
      SerpApiClient.stub(:search, ->(**_opts) { SEARCH_PAYLOAD }) do
        assert_difference "SerpSnapshot.count", expected do
          post admin_refresh_market_intelligence_path(scope: "ranks")
        end
      end
    end

    assert_redirected_to admin_market_intelligence_path
    snapshot = SerpSnapshot.latest_for(query: KEYWORD)
    assert snapshot.fresh?
    assert_equal 2, snapshot.payload["organic_results"].size
  end

  # The two halves have separate budgets on purpose: refreshing demand must not
  # re-spend the ranking quota, and vice versa.
  test "refreshing demand hits autocomplete and trends only, once per seed each" do
    sign_in_admin

    seeds = Admin::MarketIntelligenceController::DEMAND_SEEDS
    calls = []

    search = lambda do |query:, engine: nil, **opts|
      calls << [query, engine, opts[:data_type]]
      { "suggestions" => [{ "value" => "french numbers worksheet" }] }
    end

    SerpApiClient.stub(:api_key, "test-key") do
      SerpApiClient.stub(:search, search) do
        assert_difference "SerpSnapshot.count", seeds.size * 2 do
          post admin_refresh_market_intelligence_path(scope: "demand")
        end
      end
    end

    engines = calls.map { |_query, engine, _type| engine }.tally
    assert_equal seeds.size, engines["google_autocomplete"]
    assert_equal seeds.size, engines["google_trends"]
    assert_nil engines["google"]          # no SERP searches spent
    assert_nil engines["google_shopping"] # no pricing searches spent

    # Trends needs its data_type, and is the one engine that takes no location.
    trends = calls.select { |_query, engine, _type| engine == "google_trends" }
    assert trends.all? { |_query, _engine, type| type == "RELATED_QUERIES" }
  end

  test "autocomplete suggestions become demand the catalogue can be measured against" do
    SerpSnapshot.record!(query: "french worksheets", engine: "google_autocomplete", payload: {
      "suggestions" => [{ "value" => "french numbers 1 to 100 worksheet" }]
    })
    SerpSnapshot.record!(query: "french worksheets", engine: "google_trends", payload: {
      "related_queries" => { "top" => [{ "query" => "french numbers to 100", "value" => 95 }] }
    })

    sign_in_admin
    get admin_market_intelligence_path

    assert_response :success
    # Both phrasings are one topic, labelled with the shorter of the two.
    assert_match "french numbers to 100", response.body
    # Autocomplete rank 1 (100) + Trends value (95) sum onto that topic.
    assert_match "demand 195", response.body
    assert_match "2 signals", response.body
  end

  test "refresh without an API key tells the owner instead of erroring" do
    sign_in_admin

    SerpApiClient.stub(:api_key, nil) do
      assert_no_difference "SerpSnapshot.count" do
        post admin_refresh_market_intelligence_path
      end
    end

    assert_redirected_to admin_market_intelligence_path
    assert_match(/SerpApi key/, flash[:alert])
  end
end
