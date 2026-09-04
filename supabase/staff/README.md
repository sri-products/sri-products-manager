# Sri Products — Business Manager on Supabase (Phase 5)

This replaces the Google Apps Script + Sheets backend (`apps-script/Code.gs`)
with Supabase, on the **same Supabase project the storefront already
uses** — counter sales and online orders now share one database.
`js/app.js` (all the screens/forms) was **not changed** — `js/api.js`
was rewritten as a shim that keeps the exact same `Api.call(action,
params)` interface, but calls Postgres functions instead of an Apps
Script `/exec` URL.

## 1. Run the migrations, in this exact order

If you haven't already, run these first (they created the `items`,
`price_history`, `stock_balances` tables this migration builds on):
1. `supabase/schema.sql`
2. `supabase/002_delivery.sql`
3. `supabase/003_online_payment.sql`

Then run these four, **in order** — each depends on tables/functions
the previous one created:
4. `supabase/staff/004_staff_foundation.sql` — staff auth helpers,
   `customers`, `bottle_adjustments`, `stock_movements`, the empty
   `sales`/`sale_items`/`payments`/`quotations`/`quotation_items`/
   `production`/`production_inputs`/`production_outputs` tables,
   `app_settings`, and the `next_id`/`record_stock_movement`
   primitives everything else calls.
5. `supabase/staff/005_sales_payments.sql`
6. `supabase/staff/006_quotations_production.sql`
7. `supabase/staff/007_customers_items_stock_dashboard.sql`

(005/006/007 were built in parallel against a shared spec, then
reconciled for consistency — see "Judgment calls" below for what that
reconciliation actually caught, worth reading before you trust this
with real data.)

## 2. Create your first staff (Admin) account

There's no more `createFirstAdmin()` Apps Script function to run —
staff accounts are real Supabase Auth users now. To create the first
one:

1. Supabase Dashboard → Authentication → Users → **Add user**.
   - Email: pick anything under a domain you control, e.g.
     `admin@staff.sriproducts.local` (this doesn't need to be a real,
     deliverable email address — see step 3).
   - Password: set a real one.
   - Auto Confirm User: **yes** (skips email verification, which
     would otherwise never arrive for a fake domain).
2. Copy the new user's UUID (shown in the Users list).
3. SQL Editor, run:
   ```sql
   insert into staff_profiles (id, name, role, active)
   values ('<paste the uuid>', 'Administrator', 'Admin', true);
   ```
   Without this row, the account can log in to Supabase Auth
   successfully but `get_current_staff()` will reject it — api.js's
   `login()` treats that as "not set up as an active staff user" and
   signs them back out.
4. To add more staff later, repeat both steps (Dashboard user +
   `staff_profiles` row), setting `role` to `'Staff'` for non-admins.
   There's no in-app "add user" screen yet — same gap the Sheets
   version had, just with a safer underlying auth system now.

## 3. Configure the frontend

Edit `js/config.js`:
```js
window.SRI_CONFIG = {
  SUPABASE_URL: 'https://xxxx.supabase.co',
  SUPABASE_ANON_KEY: 'eyJ...',
  STAFF_EMAIL_DOMAIN: 'staff.sriproducts.local'
};
```
`STAFF_EMAIL_DOMAIN` must match whatever domain you used when creating
accounts in step 2 — staff type just `admin` as their username on the
login screen (unchanged from before), and `api.js` maps that to
`admin@staff.sriproducts.local` behind the scenes before calling
Supabase Auth. If a username already contains `@`, it's used as-is
(so a real email address also works, if you'd rather use those).

## 4. Existing Sheets data

If you have real customers/items/sales/etc. already in the Google
Sheet from using the old version of this app, that data is **not**
migrated automatically — this migration only sets up empty tables.
Given this app hasn't been used for real production data yet (per the
build history), there's nothing to import right now. If that changes
before you cut over, say so and a proper export/import script
(mapping old `ITM0004`-style Sheets IDs into `legacy_item_id` /
`legacy_customer_id` columns already reserved for this) should be
built before relying on this — don't hand-copy financial data between
systems.

## 5. Test end-to-end against the existing UI

Since `app.js` didn't change, testing this is just "use the app
normally" — but specifically exercise these, since they're the
highest-risk/most-rewritten paths:

1. **Log in** with the staff account from step 2.
2. **Products → Price book → Bottle adjustments**: add one of each,
   confirm they show up and the date-effective lookup works (add a
   price dated in the future, confirm "current price" doesn't jump to
   it yet).
3. **New sale**: add 2 line items, one with "customer's own bottle"
   checked, part-payment at time of sale. Confirm the sale detail
   screen shows the right rate/bottle-adjustment/tax breakdown, and
   Inventory shows stock decremented for both items.
4. **Edit that sale** (change a quantity), then check Inventory again
   — the old movement should be fully reversed and only the new
   quantity reflected, not double-counted. This is the single
   riskiest piece of logic in the whole migration (same one flagged
   as "most worth double-checking" in the original Code.gs README).
5. **Void a sale that has a payment recorded against it** — confirm
   its own Outstanding zeroes out but the payment record itself is
   untouched, and the customer ledger still reads sensibly afterward.
6. **Record a payment split across two of a customer's unpaid
   sales** — confirm each sale's own Outstanding dropped correctly and
   the Dashboard's Pending figure reflects it.
7. **Create a quotation, convert it to a sale** — with stock
   deliberately too low for one line item, confirm the conversion
   still completes with a stock-warning toast rather than blocking.
8. **Production entry**: add inputs/outputs, confirm Inventory moves
   both directions correctly, then edit it and confirm the old
   movement was reversed before the new one applied (same
   reverse-then-recreate risk as sale editing).
9. **Log out, then try any action** — confirm you're bounced to the
   login screen rather than seeing a raw error, and that logging back
   in works.
10. **Dashboard**: confirm today/month totals, Pending vs. "Credit
    owed to customers", and the "sold this month" breakdown all look
    right against what you just created above.

## 6. Judgment calls made reconciling the parallel migration

The Sales+Payments, Quotations+Production, and Customers/Items/Stock/
Dashboard domains were built in parallel by separate agents against a
shared spec, then reconciled. Worth knowing what that caught, since
it's exactly the kind of subtle bug this kind of split-work approach
risks:

- **`resolve_customer`'s signature disagreed between two of the three
  files** (`uuid` in one, `text` in another) — in Postgres, that
  doesn't cause an error, it silently creates *two different
  overloaded functions* with the same name, and whichever code path
  happens to match a given call's argument types wins. Fixed to a
  single `resolve_customer(text, text)` signature everywhere,
  matching what `app.js` actually ever sends (the human-readable
  `CUS-00012`-style id, never an internal uuid).
- **A stale `grant execute on function resolve_customer(uuid, text)`**
  was left behind after that fix — would have failed at migration-run
  time with "function does not exist," since the signature it
  referenced no longer existed. Fixed.
- **New items defaulted to `visible_online = true`** (the `items`
  table's default, written for the storefront's use case). Without a
  fix, every product created from Business Manager → Admin → Products
  — including raw materials never meant for sale — would have
  silently appeared for sale on the **public storefront**. Fixed:
  `create_item` now explicitly sets `visible_online = false`; making
  a product sellable online is a deliberate future step (a "show in
  storefront" toggle doesn't exist yet — flip it directly in Supabase
  if you need this before that's built).
- Each domain's individual "judgment calls" (rounding edge cases,
  sort-tiebreak differences, error-message wording) were reported by
  the agents that wrote them — if you hit a discrepancy against the
  old Apps Script behavior during testing, check that domain's file
  header comment first, it's probably already documented there.

## 7. What's still missing after this migration

Same honest gaps the original Code.gs README called out — this
migration ported the *behavior*, not the missing features:

- No in-app user management (adding/deactivating staff, changing
  passwords) — still a manual Supabase Dashboard + SQL step.
- No customer credit limits, no duplicate-customer detection.
- Negative inventory still allowed (sales/production go through even
  if they'd drive stock below zero) — same deliberate choice as
  before, now enforced nowhere any harder than it was in Sheets.
- No connection yet between this Customers table and the storefront's
  guest-checkout orders — that's the B2B accounts phase, still to come.
