# Joins what people SEARCH for (cached SerpApi data) against what this store
# actually SELLS (its catalogue + paid sales history), and reports the gap.
#
# This is the part a generic SEO tool can't do: the demand side is public search
# data, but the supply side — which worksheets exist, and which ones people
# actually paid for — is private to this store. The interesting output isn't a
# rank, it's a decision: "make this next", "make more like this", "this one
# isn't wanted".
#
# READ-ONLY. It writes nothing, and reads only what it needs: product rows,
# cached SerpSnapshot rows, and a COUNT of paid line items per product. It never
# touches an amount, a currency, a token, or an order's status.
class DemandGapAnalyzer
  # Words that appear in nearly every query in this niche, so they carry no
  # signal when deciding whether a worksheet covers a search.
  STOPWORDS = %w[
    french worksheet worksheets pdf printable print download downloadable online
    the a an and or of for to in on with your you my how what which when who
    is are do does did can i it that this best top new easy simple sheet sheets
    learn learning study practice practise exercises exercise lesson lessons
  ].freeze

  # A search containing one of these is looking for something free. Still useful
  # to see (it's real demand), but flagged — it converts badly for a paid store.
  FREE_INTENT = %w[free gratis gratuit].freeze

  # Google Trends' related queries drift: seed it with "french grammar" and it
  # will happily return "french toast near me" and "how to learn calligraphy".
  # A phrase has to actually be about French to count as demand for this store.
  NICHE_ANCHORS = %w[french francais française francaise].freeze

  # And it has to be demand for a WORKSHEET. These words mean the searcher wants
  # a different product entirely — an app, a class, a translator, a restaurant —
  # so the demand is real but not ours to serve.
  OFF_TOPIC = %w[
    toast press fries onion bulldog braid tip tips nails manicure plait crepe
    app apps course courses class classes tutor tutors teacher teachers
    institute academy school near duolingo babbel rosetta
    translate translation translator dictionary meaning pronounce pronunciation
    movie movies song songs netflix series film book books novel
    youtube video videos channel podcast alexa
    exam dates jobs job salary visa embassy citizenship immigration
    calligraphy computer keyboard typing
  ].freeze

  # Share of a phrase's meaningful words that a worksheet must match before we
  # call that phrase "covered". 0.6 tolerates one unmatched word in three.
  COVERAGE_THRESHOLD = 0.6

  # Relative weight each source contributes to a topic's demand score. Google
  # Trends is the only source that reports actual relative volume (0-100), so it
  # speaks for itself; the others are scored against that same scale.
  #   - autocomplete is ordered by popularity, so rank 1 counts for much more
  #     than rank 15, but even the tail is real demand
  #   - a "related search"/"People also ask" entry is a flat, moderate signal
  TRENDS_BREAKOUT_VALUE = 100
  AUTOCOMPLETE_TOP_WEIGHT = 100
  AUTOCOMPLETE_DECAY = 5
  AUTOCOMPLETE_FLOOR = 30
  RELATED_WEIGHT = 40

  Gap = Struct.new(:phrase, :score, :mentions, :from_question, :rising, :free_intent, keyword_init: true)
  CatalogueRow = Struct.new(:product, :units_sold, :matched_phrases, :verdict, keyword_init: true)

  # products:  the live catalogue (Product.listed)
  # snapshots: cached SerpSnapshot rows to mine for demand
  # units_sold: { product_id => paid units }
  def initialize(products:, snapshots:, units_sold:)
    @products   = products
    @snapshots  = snapshots
    @units_sold = units_sold
  end

  def self.call(products: Product.listed, snapshots: SerpSnapshot.newest_first.limit(50))
    new(products: products, snapshots: snapshots, units_sold: paid_units_by_product).call
  end

  # Paid units per product, counting BOTH rails: modern cart lines
  # (order_items) and legacy single-product orders (orders.product_id).
  # A COUNT only — no amounts are read, so nothing here can misreport revenue.
  def self.paid_units_by_product
    from_items  = OrderItem.joins(:order).merge(Order.paid).group(:product_id).count
    from_legacy = Order.paid.where.not(product_id: nil).group(:product_id).count
    from_items.merge(from_legacy) { |_id, items, legacy| items + legacy }
  end

  def call
    topics = demand_topics

    covered, uncovered = topics.partition { |key, _| covering_product(key) }

    {
      gaps:      build_gaps(uncovered),
      catalogue: build_catalogue(covered),
      phrases_considered: topics.size,
      searches_mined: @snapshots.size
    }
  end

  private

  # Demand mined from the cache, clustered by TOPIC rather than by exact string.
  #
  # "People also ask" questions and "related searches" are Google telling us, in
  # its users' own words, what they wanted. The same want arrives in several
  # phrasings — "french verb conjugation worksheet pdf" and "how do you practise
  # french verb conjugation" are one topic, not two — so phrases are keyed on
  # their meaningful words. Clustering is what makes "mentions" mean demand
  # rather than vocabulary.
  #
  # Returns { "conjugation verb" => { mentions:, from_question:, variants: [...] } }.
  def demand_topics
    topics = Hash.new { |h, k| h[k] = { score: 0, mentions: 0, from_question: false, rising: false, variants: [] } }

    @snapshots.each { |snapshot| mine(topics, snapshot.payload) }

    fold_specific_into_general(topics)
  end

  # One cached response can carry any of four demand shapes, depending on which
  # engine produced it. Google increasingly answers a SERP with an AI Overview
  # instead of "People also ask" / "Related searches", which is why autocomplete
  # and Trends carry most of the weight — they still return real user queries.
  def mine(topics, payload)
    # google — the classic blocks, when Google still shows them
    Array(payload["related_searches"]).each do |item|
      record_phrase(topics, item["query"], weight: RELATED_WEIGHT)
    end
    Array(payload["related_questions"]).each do |item|
      record_phrase(topics, item["question"], weight: RELATED_WEIGHT, question: true)
    end

    # google_autocomplete — the long tail, already ordered by popularity
    Array(payload["suggestions"]).each_with_index do |item, index|
      weight = [AUTOCOMPLETE_TOP_WEIGHT - (index * AUTOCOMPLETE_DECAY), AUTOCOMPLETE_FLOOR].max
      record_phrase(topics, item["value"], weight: weight)
    end

    # google_trends — the only source with real relative volume attached
    related = payload["related_queries"] || {}
    Array(related["top"]).each do |item|
      record_phrase(topics, item["query"], weight: trends_value(item["value"]))
    end
    Array(related["rising"]).each do |item|
      record_phrase(topics, item["query"], weight: trends_value(item["value"]), rising: true)
    end
  end

  # Trends reports a number for established queries and the string "Breakout"
  # for ones growing faster than it can measure.
  def trends_value(raw)
    return TRENDS_BREAKOUT_VALUE if raw.to_s.downcase.include?("breakout")

    [raw.to_s[/\d+/].to_i, TRENDS_BREAKOUT_VALUE].min
  end

  # Second clustering pass: a topic whose words CONTAIN another topic's words is
  # a more specific phrasing of it, so it folds in — "teach french numbers to
  # 100" belongs with "french numbers 1 to 100 worksheet", and the count of the
  # general topic is what tells her how wanted it is.
  #
  # Only topics of two or more words can absorb others, otherwise one generic
  # word ("numbers") would swallow every unrelated topic that mentions it.
  def fold_specific_into_general(topics)
    folded = {}

    topics.keys.sort_by { |key| [key.split(" ").size, key] }.each do |key|
      words = key.split(" ").to_set

      host = folded.keys.find do |general|
        general_words = general.split(" ")
        general_words.size >= 2 &&
          general_words.size < words.size &&
          general_words.to_set.subset?(words)
      end

      if host
        folded[host][:score]    += topics[key][:score]
        folded[host][:mentions] += topics[key][:mentions]
        folded[host][:from_question] ||= topics[key][:from_question]
        folded[host][:rising]        ||= topics[key][:rising]
        folded[host][:variants].concat(topics[key][:variants])
      else
        folded[key] = topics[key]
      end
    end

    folded
  end

  def record_phrase(topics, raw, weight:, question: false, rising: false)
    phrase = normalise(raw)
    words  = significant_words(phrase)
    return if words.empty? || weight.to_i <= 0 || !relevant?(phrase)

    entry = topics[words.sort.join(" ")]
    entry[:score]    += weight.to_i
    entry[:mentions] += 1
    entry[:from_question] ||= question
    entry[:rising]        ||= rising
    entry[:variants] << [phrase, question]
  end

  # The phrasing to show (and to pre-fill a worksheet title with): the shortest
  # variant that isn't a question, since "french verb conjugation worksheet" is
  # a product name and "how do you practise french verb conjugation" isn't.
  def canonical_phrase(variants)
    variants.min_by { |phrase, question| [question ? 1 : 0, phrase.length] }.first
  end

  def normalise(raw)
    raw.to_s.downcase.gsub(/[^a-z0-9\s'-]/, " ").squish
  end

  # Demand for THIS store: about French, and about something a worksheet can be.
  def relevant?(phrase)
    words = phrase.split(/[\s-]+/)

    (words & NICHE_ANCHORS).any? && (words & OFF_TOPIC).empty?
  end

  # Short words are noise — EXCEPT when they carry a digit. "grade 3" and
  # "grade 4" are different worksheets, and this store's whole catalogue is
  # organised by CEFR level, so "a1" and "b2" are among the most meaningful
  # tokens there are. Dropping them merged every grade into one topic.
  def significant_words(phrase)
    phrase.split(/[\s-]+/).reject { |word| STOPWORDS.include?(word) || !meaningful?(word) }
  end

  # Short words are noise — EXCEPT when they carry a digit. Used on BOTH sides
  # of the comparison, so a search for "french grammar a1" and a product called
  # "A1 Grammar practice pack" recognise each other.
  def meaningful?(word)
    word.length >= 3 || word.match?(/\d/)
  end

  # The best-matching live worksheet for a phrase, or nil if the catalogue
  # doesn't cover it. Matching is on meaningful words only, so "french verb
  # conjugation worksheet pdf" and a product titled "Verb Conjugation Drills"
  # are recognised as the same topic.
  def covering_product(phrase)
    @covering ||= {}
    return @covering[phrase] if @covering.key?(phrase)

    @covering[phrase] = begin
      words = significant_words(phrase)
      best  = words.empty? ? nil : @products.max_by { |product| coverage(words, product) }
      best if best && coverage(words, best) >= COVERAGE_THRESHOLD
    end
  end

  def coverage(words, product)
    matched = words.count { |word| product_words(product).include?(word) }
    matched.to_f / words.size
  end

  # Memoised per product: title + level + description are all fair game for
  # deciding what a worksheet is about.
  def product_words(product)
    @product_words ||= {}
    @product_words[product.id] ||= begin
      text = [product.title, product.level, product.description.to_s[0, 1000]].compact.join(" ")
      normalise(text).split(/[\s-]+/).select { |word| meaningful?(word) }.to_set
    end
  end

  # Uncovered demand — the "make this next" list, most-mentioned first.
  def build_gaps(uncovered)
    uncovered.map { |_key, data|
      phrases = data[:variants].map(&:first)

      Gap.new(
        phrase:        canonical_phrase(data[:variants]),
        score:         data[:score],
        mentions:      data[:mentions],
        from_question: data[:from_question],
        rising:        data[:rising],
        free_intent:   phrases.any? { |phrase| (phrase.split(/[\s-]+/) & FREE_INTENT).any? }
      )
    }.sort_by { |gap| [-gap.score, -gap.mentions, gap.phrase] }
  end

  # The catalogue, each worksheet scored on demand seen vs. units actually sold.
  def build_catalogue(covered)
    matches = Hash.new { |h, k| h[k] = [] }
    covered.each do |key, data|
      product = covering_product(key)
      matches[product.id] << canonical_phrase(data[:variants]) if product
    end

    @products.map { |product|
      units   = @units_sold[product.id].to_i
      phrases = matches[product.id]

      CatalogueRow.new(
        product:         product,
        units_sold:      units,
        matched_phrases: phrases,
        verdict:         verdict_for(units, phrases)
      )
    }.sort_by { |row| [-row.units_sold, -row.matched_phrases.size, row.product.title.to_s] }
  end

  # The whole point of joining the two data sets: sales alone can't tell you
  # whether a dud is unwanted or just undiscovered.
  def verdict_for(units, phrases)
    return :proven          if units.positive? && phrases.any?
    return :selling_quietly if units.positive?
    return :undiscovered    if phrases.any?

    :no_signal
  end
end
