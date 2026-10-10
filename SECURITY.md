# Security Policy

This code runs a live store that handles real payments and customer data.

## Reporting a vulnerability

**Please don't open a public issue or PR for security problems.**

Report them privately through GitHub instead: go to the repo's **Security** tab and
click **Report a vulnerability**. Include:

- what the problem is and where it is (file, endpoint)
- steps to reproduce it, against a **local** copy of the app
- what an attacker could do with it

You'll get a reply as soon as possible. Once a fix is deployed, you'll be credited
if you'd like.

## Rules for testing

- Test only against your own local copy (see [CONTRIBUTING.md](CONTRIBUTING.md)).
  **Never** test against the live store, its API, or its payment flows.
- Don't access, change, or keep any real customer data.
- Don't run load or denial-of-service tests.

## In scope

Payment and webhook verification, download-token handling, admin authentication,
rate limiting, and anything that could expose customer data or let someone get a
worksheet without paying.
