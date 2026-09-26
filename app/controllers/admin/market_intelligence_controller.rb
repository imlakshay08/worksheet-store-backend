# Read-only market research for the store owner, powered by SerpApi.
#
# Two jobs:
#   1. Rank & price snapshot — where we sit in Google for the keywords we care
#      about, and what comparable worksheets sell for elsewhere. Served from
#      cached SerpSnapshot rows; only "Refresh" spends SerpApi searches.
#   2. Topic opportunity finder — a live, on-demand look at what people
#      actually ask/search around a worksheet idea, so the next worksheet is
#      one there's demand for.
#
# Deliberately isolated: this controller reads no Order, writes no money, and
# touches nothing in the payment/webhook/download path. Its only writes are
# SerpSnapshot cache rows.
class Admin::MarketIntelligenceController < Admin::BaseController
  # Our storefront, matched against organic result hostnames.
  OUR_DOMAIN = "frenchworksheethub.com".freeze

  # The keywords we want to rank for. Edit this list as the catalogue grows.
  TRACKED_KEYWORDS = [
    "french worksheets pdf",
    "french verb conjugation worksheet",
    "french worksheets for beginners",
    "printable french worksheets for kids",
    "learn french a1 worksheets"
  ].freeze

  # What comparable worksheets sell for. Google Shopping is a different SerpApi
  # engine, cached in the same table under its own engine name.
  PRICING_QUERY  = "french worksheets printable pdf".freeze
  PRICING_ENGINE = "google_shopping".freeze
  SEARCH_ENGINE  = "google".freeze
  SEARCH_LOCATION = "India".freeze

  # Broad seeds for the demand side. Google's own SERP increasingly answers a
  # query with an AI Overview instead of "People also ask" / "Related searches",
  # so demand is mined from two engines that reliably return real user queries:
  #
  #   google_autocomplete — the long tail, ordered by popularity
  #   google_trends       — related queries WITH relative volume (0-100)
  #
  # Seeds are deliberately broad: they're what we expand FROM, not what we
  # expect to rank for.
  DEMAND_SEEDS = [
    "french worksheets",
    "learn french",
    "french grammar"
  ].freeze

  AUTOCOMPLETE_ENGINE = "google_autocomplete".freeze
  TRENDS_ENGINE       = "google_trends".freeze

  # Each refresh is split in two so neither half has to spend the other's
  # quota. The button labels carry these numbers.
  RANKS_COST  = TRACKED_KEYWORDS.size + 1
  DEMAND_COST = DEMAND_SEEDS.size * 2

  Ranking = Struct.new(:keyword, :position, :url, :competitors, :fetched_at, :fresh, keyword_init: true)
  Listing = Struct.new(:title, :price, :extracted_price, :source, :link, keyword_init: true)

  def index
    @configured   = SerpApiClient.configured?
    @tracked      = TRACKED_KEYWORDS
    @our_domain   = OUR_DOMAIN
    @ranks_cost   = RANKS_COST
    @demand_cost  = DEMAND_COST

    @rankings = TRACKED_KEYWORDS.map { |keyword| ranking_for(keyword) }
    load_pricing
    load_demand_gap

    # Topic finder: a live call, on demand, only when the form was submitted.
    @topic = params[:topic].to_s.strip.first(120)
    research_topic if @topic.present?
  end

  # Spend SerpApi searches to re-cache one half of the page. POST-only so a page
  # reload or a crawler can never burn quota, and split by scope so refreshing
  # demand doesn't also re-spend the ranking budget.
  def refresh
    unless SerpApiClient.configured?
      return redirect_to admin_market_intelligence_path,
                         alert: "Add your SerpApi key to Rails credentials first."
    end

    fetched = 0
    failed  = []

    searches_for(params[:scope]).each do |query, engine, extra|
      fetch_and_cache(query: query, engine: engine, extra: extra || {})
      fetched += 1
    rescue SerpApiClient::Error => e
      failed << query
      log_serp_error(query, e)
    end

    notice = "Refreshed #{pluralize_searches(fetched)} from SerpApi."
    notice += " Couldn't fetch: #{failed.join(', ')}." if failed.any?

    redirect_to admin_market_intelligence_path, notice: notice
  end

  private

  # [query, engine, extra params] for the half being refreshed. "demand" mines
  # what people search for; "ranks" checks where we sit and what others charge.
  def searches_for(scope)
    demand = DEMAND_SEEDS.flat_map do |seed|
      [[seed, AUTOCOMPLETE_ENGINE, {}],
       [seed, TRENDS_ENGINE, { data_type: "RELATED_QUERIES" }]]
    end

    ranks = TRACKED_KEYWORDS.map { |keyword| [keyword, SEARCH_ENGINE, {}] } +
            [[PRICING_QUERY, PRICING_ENGINE, {}]]

    case scope
    when "demand" then demand
    when "ranks"  then ranks
    else               demand + ranks
    end
  end

  # ---- demand gap ---------------------------------------------------------

  # The headline card: public search demand joined against this store's own
  # catalogue and paid sales. Reads only cached snapshots, so it costs nothing
  # to render and works offline from SerpApi.
  def load_demand_gap
    analysis = DemandGapAnalyzer.call

    @gaps               = analysis[:gaps].first(12)
    @catalogue_rows     = analysis[:catalogue]
    @searches_mined     = analysis[:searches_mined]
    @phrases_considered = analysis[:phrases_considered]
  end

  # ---- rankings -----------------------------------------------------------

  def ranking_for(keyword)
    snapshot = SerpSnapshot.latest_for(query: keyword, engine: SEARCH_ENGINE)
    return Ranking.new(keyword: keyword, competitors: []) if snapshot.nil?

    organic = Array(snapshot.payload["organic_results"])
    ours    = organic.find { |result| ours?(result["link"]) }

    Ranking.new(
      keyword:     keyword,
      position:    ours && (ours["position"] || organic.index(ours).to_i + 1),
      url:         ours && ours["link"],
      competitors: organic.first(5).map { |result| competitor_from(result) },
      fetched_at:  snapshot.fetched_at,
      fresh:       snapshot.fresh?
    )
  end

  def competitor_from(result)
    {
      position: result["position"],
      domain:   domain_of(result["link"]),
      title:    result["title"],
      link:     result["link"],
      ours:     ours?(result["link"])
    }
  end

  def ours?(link)
    domain_of(link).to_s.end_with?(OUR_DOMAIN)
  end

  def domain_of(link)
    host = URI.parse(link.to_s).host
    host&.delete_prefix("www.")
  rescue URI::InvalidURIError
    nil
  end

  # ---- pricing ------------------------------------------------------------

  def load_pricing
    snapshot = SerpSnapshot.latest_for(query: PRICING_QUERY, engine: PRICING_ENGINE)
    @pricing_query      = PRICING_QUERY
    @pricing_fetched_at = snapshot&.fetched_at
    @pricing_fresh      = snapshot&.fresh?

    listings = Array(snapshot&.payload&.[]("shopping_results")).first(8).map do |result|
      Listing.new(
        title:           result["title"],
        price:           result["price"],
        extracted_price: result["extracted_price"],
        source:          result["source"],
        link:            result["product_link"].presence || result["link"]
      )
    end

    @listings = listings
    # Median rather than mean: a single mispriced bundle shouldn't move it.
    # Prices come back in whatever currency Google served the query in, so this
    # is labelled "as listed" in the view rather than converted.
    prices = listings.filter_map { |l| l.extracted_price&.to_f }.sort
    @median_price = prices.empty? ? nil : prices[prices.size / 2]
  end

  # ---- topic finder -------------------------------------------------------

  def research_topic
    unless SerpApiClient.configured?
      @topic_error = "Add your SerpApi key to Rails credentials first."
      return
    end

    payload = SerpApiClient.search(query: @topic, engine: SEARCH_ENGINE, location: SEARCH_LOCATION)

    @related_questions = Array(payload["related_questions"]).first(10).map do |item|
      { question: item["question"], snippet: item["snippet"], link: item["link"] }
    end
    @related_searches = Array(payload["related_searches"]).first(12).filter_map { |item| item["query"] }
  rescue SerpApiClient::Error => e
    log_serp_error(@topic, e)
    @topic_error = "SerpApi couldn't answer that one. #{e.message.truncate(200)}"
  end

  # ---- shared -------------------------------------------------------------

  def fetch_and_cache(query:, engine:, extra: {})
    # Trends takes a geo, not a SerpApi location string, so only the SERP-style
    # engines get one.
    location = engine == TRENDS_ENGINE ? nil : SEARCH_LOCATION
    payload  = SerpApiClient.search(query: query, engine: engine, location: location, **extra)

    SerpSnapshot.record!(query: query, engine: engine, payload: trim(payload))
  end

  # Keep only what the page renders. Full SerpApi responses are large, and the
  # dropped keys (search_parameters especially) are the ones most likely to
  # carry request details we don't want sitting in the database.
  def trim(payload)
    payload.slice(
      "organic_results", "related_questions", "related_searches", "shopping_results",
      "suggestions",      # google_autocomplete
      "related_queries"   # google_trends
    )
  end

  def log_serp_error(query, error)
    Rails.logger.warn("[market_intelligence] #{error.class}: #{error.message} (query=#{query.inspect})")
  end

  def pluralize_searches(count)
    view_context.pluralize(count, "search")
  end
end
