# Contributing

Thanks for your interest! This is the backend of a **live store that takes real
payments**, so the rules below are a bit stricter than in a toy project. They exist
to keep customers' money and downloads safe, not to keep you out.

## Local setup (no API keys needed)

You need **Ruby 3.1.4** and **PostgreSQL**. Nothing else: no payment, email,
storage or SerpApi keys.

```bash
git clone https://github.com/<your-username>/worksheet-store-backend.git
cd worksheet-store-backend
bundle install

bin/rails db:setup        # create, migrate, seed demo data
bin/rails server          # http://localhost:3000
bin/rails test            # must pass before you open a PR
```

Sign in to the admin at `/admin/login` as `nidhi` / `worksheet-demo`. That demo
password only works in development and test when no credentials are configured.

By default, development and test connect to PostgreSQL on `127.0.0.1` as user
`postgres` with no password (see `config/database.yml`). If `db:setup` can't connect,
check that PostgreSQL is running and that this role exists and can create databases.
Don't commit changes to `database.yml` that only apply to your own machine.

## How to contribute

1. **Pick an issue** labelled `good first issue` and comment that you're working on
   it, so two people don't do the same thing. Issues are assigned first come,
   first served.
2. **One issue per PR**, and keep it small. A focused 30-line PR gets reviewed fast. A
   500-line PR that also reformats unrelated files will probably be closed.
3. **Add or update tests** for any behaviour change. `bin/rails test` must pass.
4. **Describe what you changed and how you checked it** in the PR description.
5. Don't commit secrets, `config/master.key`, `.env` files, or anything from
   `storage/`.

## Maintainer-only areas

Please **don't open PRs that change these** unless an issue explicitly invites you
to. They handle money, access and customer data, and a subtle bug here costs real
customers real money:

- Payment and webhook code: `app/controllers/webhooks_controller.rb`,
  `app/controllers/orders_controller.rb`, `app/services/paypal_client.rb`
- Download tokens and fulfilment: `app/controllers/downloads_controller.rb`, and
  the fulfilment/refund logic in `app/models/order.rb`
- Authentication and rate limiting: `app/controllers/admin/sessions_controller.rb`,
  `app/controllers/admin/base_controller.rb`, `config/initializers/rack_attack.rb`
- Credentials, deployment and migrations: `config/credentials*`, `Dockerfile`,
  `bin/docker-entrypoint`, `db/migrate/`

**Tests** for these areas are welcome. Changes to the code itself are not.

## Code style

Match the code around your change: two-space indentation, short methods, and a
comment where the *why* isn't obvious. Don't reformat files you aren't otherwise
changing.

By contributing, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
