# Cache table for SerpApi responses backing the read-only Market Intelligence
# admin page. Purely additive: no existing table is touched, so this is safe to
# auto-run on deploy alongside live order data.
class CreateSerpSnapshots < ActiveRecord::Migration[7.1]
  def change
    create_table :serp_snapshots do |t|
      t.string   :query,   null: false
      t.string   :engine,  null: false, default: "google"
      t.jsonb    :payload, null: false, default: {}
      t.datetime :fetched_at, null: false

      t.timestamps
    end

    # The only lookup we do: newest snapshot for one (query, engine) pair.
    add_index :serp_snapshots, [:query, :engine, :fetched_at]
  end
end
