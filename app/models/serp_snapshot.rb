# A cached SerpApi response for one (query, engine) pair.
#
# The free SerpApi tier is a small monthly search budget, so the admin's
# Market Intelligence page reads from here and only spends a search when the
# owner explicitly hits "Refresh". Rows are append-only history — we always
# read the newest one — which also makes rank movement visible over time.
class SerpSnapshot < ApplicationRecord
  FRESH_FOR = 12.hours

  validates :query,  presence: true, length: { maximum: 255 }
  validates :engine, presence: true, length: { maximum: 50 }

  scope :for_search, ->(query, engine) { where(query: query, engine: engine) }
  scope :newest_first, -> { order(fetched_at: :desc) }
  scope :fresh, -> { where(fetched_at: FRESH_FOR.ago..) }

  # Newest still-fresh snapshot for a search, or nil.
  def self.fresh_for(query:, engine: "google")
    for_search(query, engine).fresh.newest_first.first
  end

  # Newest snapshot for a search regardless of age, or nil. The page shows a
  # stale row (clearly labelled) rather than nothing, so the owner can still
  # see last week's ranking without spending a search.
  def self.latest_for(query:, engine: "google")
    for_search(query, engine).newest_first.first
  end

  # Store a response. `payload` is already trimmed by the caller to the keys the
  # page renders, so these rows stay small and never hold request credentials.
  def self.record!(query:, engine:, payload:)
    create!(query: query, engine: engine, payload: payload, fetched_at: Time.current)
  end

  def fresh?
    fetched_at.present? && fetched_at > FRESH_FOR.ago
  end

  def age_in_words
    return "never" if fetched_at.blank?

    "#{ActionController::Base.helpers.time_ago_in_words(fetched_at)} ago"
  end
end
