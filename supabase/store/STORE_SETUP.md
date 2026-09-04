# Sri Products — Storefront (Phase 1 + Phase 2)

Public storefront: browse products, add to cart, guest checkout,
**pickup or delivery, pay in person either way** (pay-at-pickup or
pay-on-delivery — no online payment gateway yet, that's Phase 3). No
login yet either — that's Phase 4 alongside B2B accounts. Runs on
Supabase (Postgres), separate from the internal Business Manager app
for now.

## Phase 2 update: delivery + shipping

If you already ran `schema.sql` for Phase 1, run **`supabase/002_delivery.sql`**
now too (SQL Editor, same project) — it's an additive migration, safe
to run on a database that already has real orders in it. It adds:
- A `store_settings` table (`delivery_fee`, `free_delivery_threshold`)
  so you can tune the shipping rule without touching code — edit those
  two rows directly in Table Editor.
- Delivery address columns on `orders`, and `shipping_fee` /
  `grand_total` columns alongside the existing `subtotal`.
- A delivery-aware `create_order` (now takes a fulfillment type +
  address fields) and `get_order_status` (now returns shipping/total
  and the delivery address for the customer's own order).

The shipping rule is deliberately simple: free above the threshold,
flat fee below it. It is **not** a real courier rate lookup — there's
no integration with Delhivery/Shiprocket/etc. yet. That's a fine
starting point but don't assume it reflects your actual delivery cost
per order, especially for heavy items or far pincodes.

## 1. Set up Supabase

1. Create a project at [supabase.com](https://supabase.com) (free tier).
2. Open the SQL Editor and run `../supabase/schema.sql` (in the repo
   root's `supabase/` folder, one level up from this `store/` folder).
   It creates the tables, the public read-only views, the
   `create_order` / `get_order_status` / `cancel_order` functions, the
   RLS policies, and inserts 3 sample products so you have something
   to test with immediately.
3. Project Settings → API → copy the **Project URL** and **anon public**
   key. Do **not** use the `service_role` key anywhere in this folder —
   it bypasses Row Level Security and must never ship in frontend code.

## 2. Configure the frontend

Edit `js/config.js`:
```js
window.STORE_CONFIG = {
  SUPABASE_URL: 'https://xxxx.supabase.co',
  SUPABASE_ANON_KEY: 'eyJ...'
};
```

## 3. Run it locally / deploy it

No build step. Either:
- Open `index.html` directly, or serve the folder with any static
  server (`npx serve .`, VS Code "Live Server", etc.) — a real HTTP
  server is safer than `file://` for CORS behavior with Supabase.
- Deploy the `store/` folder to GitHub Pages, Netlify, Vercel, or
  Cloudflare Pages — it's fully static.

Keep this on a different path/subdomain than the internal Business
Manager (e.g. `shop.sriproducts.com` vs. the staff app) since they're
different audiences and, later, different auth models.

## 4. Test the end-to-end flow

1. Load the site — you should see the 3 sample products from the seed
   data with prices and "100 [unit] available".
2. Add a couple to your cart, go to Checkout, fill in a name + 10-digit
   phone + pickup location, place the order.
3. You'll land on the order confirmation screen with an order number
   (e.g. `ORD-000001`) and a "Cancel this order" option (only while
   status is `pending`).
4. In the Supabase dashboard → Table Editor → `orders`, confirm the row
   exists with the right subtotal, and that `stock_balances.reserved`
   went up by the quantity ordered for each item.
5. Use "Track an order" from the footer nav with the same order number
   + phone to confirm guest lookup works.
6. Try a mismatched phone number on that same order number — it should
   say "Order not found" rather than revealing anything about the real
   order (this is deliberate, see `get_order_status` in schema.sql).
7. After running `002_delivery.sql`: on Checkout, switch to "Delivery",
   fill in an address + 6-digit pincode, and confirm the shipping fee
   shown matches `store_settings` (₹49 by default, free above ₹999
   subtotal — add enough quantity to cross that threshold and confirm
   it switches to "Free"). Confirm the order confirmation and "Track an
   order" screens both show the delivery address and the shipping
   line correctly.

## 5. Managing orders (Phase 1 has no admin screen yet)

Until the Business Manager is migrated onto this same Supabase project
and gets a real Orders screen, **use the Supabase dashboard's Table
Editor directly** as your interim admin tool:
- `orders` — update `status` (`pending` → `confirmed` → `ready` →
  `completed`) and `payment_status` as you take payment and hand over
  the order. Delivery orders carry their address in the
  `delivery_address_*` columns and their shipping cost in
  `shipping_fee`/`grand_total` on the same row.
- `items` / `price_history` / `stock_balances` — add real products,
  set real prices, set real stock levels. Delete the sample rows from
  `schema.sql`'s seed data first.
- `pickup_locations` — replace the placeholder address with your real
  one(s).

This is manual and not meant to be permanent — it's the fastest way to
get Phase 1 live without also building an admin UI before you've
validated anyone wants to order online at all.

## Phase 3: online prepay (Razorpay)

Adds a "Pay online now" option alongside pay-at-pickup/pay-on-delivery.
Payment confirmation is never trusted from the browser alone — the
trust boundary is three Edge Functions that hold secrets no frontend
file ever sees.

### 3a. Razorpay account (you do this — I can't sign up on your behalf)

1. Sign up at [razorpay.com](https://razorpay.com). **Test mode is
   available immediately, no KYC needed** — you can build and test the
   whole flow before your business verification/KYC (needed for Live
   mode) is approved.
2. Dashboard → Settings → API Keys → generate a **Test mode** key pair.
   Note the **Key Id** and **Key Secret**. Never put the Key Secret in
   any frontend file — it only ever goes into Edge Function secrets
   (next section).
3. Don't set up the webhook yet — it needs the Edge Function's URL,
   which you only get after deploying (step 3c).

### 3b. Install the Supabase CLI and link your project (one-time)

```
npm install -g supabase
supabase login
supabase link --project-ref <your-project-ref>   # find this in your Supabase project URL
```

### 3c. Deploy the Edge Functions and set their secrets

Run these from the **`App` folder itself** (the one that *contains*
`supabase/`), not from inside `supabase/` — the CLI resolves function
code as `./supabase/functions/<name>` relative to your current
directory, so `cd`-ing into `supabase` first breaks the path. Also
make sure **Docker Desktop is running** first — the CLI needs it
running to bundle the function before upload; you'll get a
`Docker is not running` warning followed by a confusing "file not
found" error otherwise.

```
cd "path\to\App"
supabase link --project-ref <your-project-ref>   # if you haven't linked from this exact folder yet

supabase functions deploy create-razorpay-order
supabase functions deploy verify-payment
supabase functions deploy razorpay-webhook

supabase secrets set RAZORPAY_KEY_ID=<your test key id>
supabase secrets set RAZORPAY_KEY_SECRET=<your test key secret>
supabase secrets set RAZORPAY_WEBHOOK_SECRET=<pick any random string, e.g. `openssl rand -hex 20`>
```

`supabase link` remembers the project per-folder, so if you previously
ran `supabase init`/`link` somewhere else (e.g. a stray `supabase`
folder created directly under your user directory), that link doesn't
carry over here — re-run `supabase link` from inside `App` itself.
`SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` don't need to be set
manually — Supabase injects those into every Edge Function
automatically.

After deploying, each function's URL is:
`https://<project-ref>.supabase.co/functions/v1/<function-name>`

### 3d. Register the webhook in Razorpay

Dashboard → Settings → Webhooks → **Add New Webhook**:
- Webhook URL: `https://<project-ref>.supabase.co/functions/v1/razorpay-webhook`
- Secret: the exact same random string you set as `RAZORPAY_WEBHOOK_SECRET` above
- Active events: check **`payment.captured`** (and `order.paid` if you
  want the redundancy — either is enough, `mark_order_paid` is
  idempotent so receiving both for the same payment is harmless)

### 3e. Run the migration

Run **`supabase/003_online_payment.sql`** in the SQL Editor (after
`schema.sql` and `002_delivery.sql`).

### 3f. Test it (test mode — no real money moves)

1. On Checkout, choose "Pay online now," place the order — Razorpay's
   Checkout widget should open.
2. Use a [Razorpay test card](https://razorpay.com/docs/payments/payments/test-card-details/)
   (e.g. `4111 1111 1111 1111`, any future expiry, any CVV) or test
   UPI (`success@razorpay`) to simulate a successful payment.
3. You should land on the order status screen showing `payment_status:
   paid` almost immediately (via verify-payment). Confirm in Table
   Editor → `orders` that `payment_status = 'paid'`, `status =
   'confirmed'`, and `razorpay_payment_id` is filled in.
4. Now test the *closed-tab* case, which is what the webhook exists
   for: place another online order, and when Checkout opens, complete
   the test payment but immediately close the browser tab before this
   app's own success handler can run. Wait a few seconds, then check
   Table Editor directly — the order should still flip to `paid`,
   proving the webhook (not just the in-browser callback) did its job.
5. Test the abandoned case: place an online order, then dismiss/close
   the Razorpay widget without paying. You should land on the order
   status screen with a "Pay now" button and `payment_status: unpaid`
   — click "Pay now" and confirm it reopens Checkout for the *same*
   Razorpay order (check `razorpay_order_id` in Table Editor doesn't
   change between attempts).
6. Try tampering: open browser dev tools and call `Sb.client.rpc('mark_order_paid', ...)`
   directly from the console. It should fail — that function is not
   granted to `anon`, so only the service-role-holding Edge Functions
   can call it.

Only switch `RAZORPAY_KEY_ID`/`RAZORPAY_KEY_SECRET` to your Live mode
keys (via `supabase secrets set`, same commands as above) once KYC is
approved and you've fully tested in test mode — there's no separate
code path for test vs. live, just which keys are configured.

## What's deliberately not in Phase 1 + 2 + 3

- No real courier/shipping-rate integration — `delivery_fee` is a flat
  number you set, not a live rate from a carrier API.
- No automatic release of stock reserved by an online order that's
  never paid — `release_expired_online_orders()` exists but has to be
  run manually (SQL Editor) or scheduled yourself via Supabase's
  `pg_cron` extension. Worth doing before this is public; an unpaid,
  abandoned checkout otherwise holds that stock reserved forever.
- No refund flow — cancelling a *paid* order doesn't refund it
  automatically (only `pending`/unpaid orders can self-serve cancel).
  A paid-and-cancelled order needs a manual refund from the Razorpay
  dashboard for now.
- Razorpay Checkout is loaded from Razorpay's own CDN
  (`checkout.razorpay.com`) with no version pin — that's normal for
  this widget specifically (it's not an npm dependency, and Razorpay
  manages it as a stable, always-current, PCI-relevant endpoint), but
  worth knowing it's the one script in this project you don't control
  the version of.
- No customer accounts / login — guest checkout, order lookup by
  order number + phone.
- No B2B pricing tiers (`customer_price_overrides` table exists in the
  schema but nothing writes to it yet).
- No connection to the existing Google Sheets Business Manager — this
  is a standalone Supabase project. Migrating the Business Manager
  onto the same database (so online orders and phone/counter sales
  share one system) is a separate, later step.
- Stock reservations (`stock_balances.reserved`) are held forever once
  an order is placed and never auto-released except by explicit
  cancellation — there's no "pending order timeout" job yet. Since
  there's no online payment to abandon mid-checkout, this is a smaller
  risk than it would be once online prepay is added, but a customer who
  places an order and never shows up (or never accepts delivery) will
  hold that stock reserved until someone manually cancels or completes
  the order in Table Editor.
- No delivery zone restrictions — any pincode is accepted right now,
  even ones you might not actually be able to deliver to. Worth adding
  a pincode allowlist/blocklist before this is public if your delivery
  range is limited.
