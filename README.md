# Sri Products — Business Manager

A mobile-first web app for sales, quotations, customers, payments, production,
and inventory — static frontend on GitHub Pages, Google Apps Script as the
API, Google Sheets as storage.

## 1. Set up the Sheet + backend

1. Create a new Google Sheet (this becomes your database).
2. Extensions → Apps Script. Delete the default `Code.gs` content and paste
   in `apps-script/Code.gs` from this project.
3. In the Apps Script editor, select `setupSheets` from the function
   dropdown (top toolbar) and click **Run**. Approve the permissions prompt.
   This creates every sheet tab and its headers.
4. Edit the `createFirstAdmin` function — set your real username and a
   password — then select it and **Run** once. This is your first login.
   **Change this password's username/password pair, or delete the function's
   hard-coded values, right after this step** — leaving a known password in
   the script source is a real credential left lying around.
5. Deploy → New deployment → type **Web app**.
   - Execute as: **Me**
   - Who has access: **Anyone**
   - Click Deploy, approve permissions, copy the URL ending in `/exec`.
6. Any time you change `Code.gs` later, you must **Deploy → Manage
   deployments → Edit → New version**, or the live URL keeps serving old
   code.

## 2. Set up the frontend

1. Open `js/config.js` and replace `PASTE_YOUR_APPS_SCRIPT_WEB_APP_URL_HERE`
   with the `/exec` URL from step 1.5 above.
2. Push this folder to a GitHub repo, enable GitHub Pages (Settings → Pages
   → deploy from branch), and point it at this folder.
3. Open the Pages URL on a phone, log in with the admin account from step
   1.4.
4. Add your real products first (More → Admin → Products), then set prices
   (More → Admin → Price book) and bottle adjustments before creating any
   sales — a sale will fail with "no price set" for an item with no price
   row on or before the sale date.

## 3. Performance: StockBalances (latest)

`getCurrentStock()` used to sum the *entire* `StockMovements` history —
every sale, production entry, and adjustment ever recorded — on every
dashboard load, inventory screen, and sale/quotation stock check. Fine
today, but that cost grows forever as the ledger grows.

Fixed by adding a `StockBalances` sheet: one row per item, holding a
running total that's updated by ±quantity every time a movement is
recorded, instead of recomputed from scratch. `StockMovements` is
untouched — it's still the full audit ledger, still append-only, still
what the per-item history screen reads. `StockBalances` is just a
cache of "what does that ledger currently sum to," kept in sync
incrementally rather than recomputed.

**After deploying this**: run `setupSheets` once from the editor. It
creates the new sheet and — this is the important part — automatically
backfills it from your existing `StockMovements` history the first time
it runs, so your current stock numbers won't reset to zero. Safe to
re-run; it only backfills when the sheet is empty.

If stock numbers ever look wrong after this — a bug, a manually-edited
cell, anything — there's a recovery function: run `rebuildStockBalances`
from the Apps Script editor. It recomputes every item's balance from the
full ledger and overwrites `StockBalances` with the result. It's not
exposed in the app UI on purpose — this is a "something's wrong, fix it"
tool, not a routine action.

## 4. Payments, sales filters, dashboard breakdown (previous update)

- **Fixed a real bug**: recording a payment against a specific sale
  previously only logged a `Payments` row — it never updated that sale's
  own `AmountReceived`/`Outstanding`. Now it does. This matters because
  filters, "Mark as paid," and the new split-payment feature all depend
  on a sale's own numbers being accurate, not just the customer-level
  total.
- **Sales list**: shows customer name, date, and a summary of items
  bought instead of the Sale ID; added a customer search box and
  All/Unpaid/Partially paid/Paid filter chips.
- **Sale detail**: added a "Mark as paid" button (only shown when
  something's still owed) that records a payment for the exact
  outstanding amount in one tap.
- **Record payment**: customer is now a required autocomplete pick, not
  free text — you can't record a payment against a customer that doesn't
  exist, since there'd be nothing to apply it to. If the customer has
  multiple unpaid sales, entering a total amount auto-splits it across
  them oldest-first (editable per line) instead of forcing you to record
  separate payments one sale at a time.
- **Autocomplete rebuilt as a custom dropdown**, replacing the native
  `<datalist>` from the previous update — datalist barely renders on iOS
  Safari, so anyone on an iPhone would have seen no suggestions at all.
- **Dashboard**: added a monthly "sold this month" breakdown per oil and
  cake by-product, and split what was one "Outstanding" number into
  "Pending" (money owed to you) and "Credit owed to customers" (only
  shown when nonzero — covers the overpayment/credit case that a single
  netted number was hiding).

## 5. Edit/void/delete, customer autocomplete (earlier update)

- **Price book and bottle-adjustment history are now editable and
  deletable in place**, not append-only. This is safe because Sale/
  Quotation line items snapshot the rate at the moment they're created —
  editing a past price row does not retroactively change any past
  transaction, it only affects what the *next* sale looks up.
- **Sales get Edit and Void**, Quotations get Edit and Delete, Production
  entries get Edit and Delete. See the pushback at the top of this
  response (and repeated below) for why Sales/Production use Void/
  reversal-on-delete instead of a plain row delete.
- **Customer entry on Sale/Quotation is now free text with suggestions**,
  not a required dropdown pick. Typing a name that doesn't match an
  existing customer (case-insensitive, exact match only) creates one
  automatically on save; a hint under the field tells you when that's
  about to happen.
- **Price book's list view shows each product's current price inline**,
  no need to tap into each item to see what it's set to.
- **You must re-run `setupSheets`** after pulling this update — it now
  also patches missing columns onto sheets that already exist (adds
  `Sales.Status`, `Sales.VoidReason`, etc.) without touching your
  existing rows. Safe to run repeatedly.

## 6. Judgment calls made building this — read before relying on it

You told me to go ahead rather than wait on the open questions from the
design review. I made a call on each one. These are the calls, not
guarantees they're the calls you'd have made:

- **Negative inventory: allowed, not blocked.** A sale or production entry
  goes through even if it drives an item's stock below zero. The Inventory
  screen shows negative/zero stock in red so it's visible, but nothing
  stops the transaction. If you want sales blocked at insufficient stock,
  that's a real behavior change, not a tweak — say so and I'll change it.
- **Quotation → Sale conversion with insufficient stock: allowed, with a
  warning.** The conversion completes; you get a toast listing which items
  came up short. Same reasoning as above — flag if you want a hard block
  instead.
- **Overpayments: allowed, uncapped.** Nothing stops recording a payment
  larger than the outstanding balance. It just makes Outstanding go
  negative on that customer's ledger. There's no "credit balance" concept
  surfaced anywhere else in the UI — it's purely a number.
- **Price and bottle-adjustment corrections: append-only.** There is no
  in-place edit. To correct a mistake, add a new dated row (today or
  backdated) — the old row stays in history. Two rows for the same item on
  the exact same date are rejected as duplicates.
- **Products: Deactivate, not Delete.** A product that's ever been used in
  a sale, quotation, or production entry has rows elsewhere that name it
  by ID — deleting it would leave those screens showing a broken
  reference instead of a product name. Deactivating removes it from
  pickers going forward while keeping history intact; you can reactivate
  it any time from the same screen.
- **Sales: Void, not Delete.** A sale has a stock movement and possibly a
  payment tied to it. Voiding (Admin-only, reason required) reverses the
  stock with an offsetting ledger entry, zeroes the outstanding balance,
  and excludes it from revenue totals — but keeps the row, so nothing
  downstream breaks and there's a record that it happened and why. If you
  need actual row deletion for some compliance reason, that's a different
  and riskier feature — ask for it explicitly rather than assuming Void
  covers it.
- **Production: real delete, because nothing downstream references a
  production entry by ID the way Sales does via `QuotationRef`.**
  Deleting one reverses both its input and output stock movements with
  offsetting entries first, then removes the record. Admin-only.
- **Stock adjustments: "Undo" reverses, it doesn't erase.** Consistent
  with treating `StockMovements` as an append-only ledger throughout —
  nothing in that sheet is ever mutated or removed, corrections are
  always a new offsetting row.
- **Customer name matching on Sale/Quotation: exact, case-insensitive,
  no fuzzy matching.** Typing a name that doesn't match an existing
  customer creates a new one on save — the form shows "This will be
  added as a new customer" as soon as what's typed doesn't match, but it
  doesn't block you from proceeding. Two staff members spelling the same
  customer differently will still produce two customer records; nothing
  in this build catches that after the fact. If duplicate customers turn
  out to be a real problem, a periodic "possible duplicates" report or a
  merge tool would be the fix — neither exists yet.
- **Customer credit limits: not built.** Outstanding balance is shown but
  never blocks a new sale.
- **Split-payment allocation is capped by each sale's own outstanding in
  the auto-split, but not if you edit a row by hand.** Typing a number
  larger than a sale's due amount is allowed (consistent with the
  earlier "overpayments allowed" decision) — it just creates a credit on
  that specific sale, which shows up in the dashboard's "Credit owed to
  customers" tile. If you want per-row entry capped at that sale's due
  amount, that's a one-line change — say so.
- **Offline use: not handled.** Every screen needs a live connection to the
  Apps Script URL. If you're recording sales somewhere with patchy signal,
  this will be a real problem, not a cosmetic one — failed saves currently
  just show an error toast and lose nothing already-typed, but they don't
  queue and retry.
- **PDF / share-image generation: browser print, not a generated file.**
  Sale and Quotation detail screens have a "Print / Share PDF" button that
  calls the browser's print dialog (which can save to PDF on most phones).
  This is not the same as a server-generated branded PDF or share-image —
  it's a real scope cut from the original spec, done to keep this
  deliverable shippable. A proper version would render through Apps
  Script's Docs/PDF export against a template.
- **Ledger reconciliation:** `Sales.Outstanding` is a snapshot taken when
  the sale is created (GrandTotal minus AmountReceived at that moment). The
  customer ledger screen (`getCustomerLedger`) recomputes outstanding from
  the full Sales + Payments history instead of trusting that stored field,
  so it stays correct even as payments come in later — but the dashboard's
  "Total outstanding" tile currently sums the stored per-sale snapshots,
  which is the same total *only if every payment against a sale is entered
  with that sale referenced correctly*. A payment recorded against a
  customer without picking the specific sale won't reduce that sale's
  stored Outstanding. Worth knowing before you trust that dashboard number
  for anything beyond a rough read.

## 7. What's genuinely untested

This was built and reviewed for logical correctness but not run against a
live deployment — I don't have a way to execute Apps Script or hit GitHub
Pages from here. Concretely test, before trusting it with real business
data:

- The CORS `text/plain` workaround actually clears preflight in your
  browser.
- ID generation under two near-simultaneous submissions (open two tabs,
  submit two sales for the same customer within a second of each other,
  confirm you get two different Sale IDs, not one skipped/duplicated).
- GST tax math once you turn `gstEnabled` on, against a manually
  calculated example.
- What happens the first time you try a sale before any price exists for
  an item (should fail with a clear message, not a silent wrong number).
- Editing a Sale, then checking that the *old* stock movement was
  correctly reversed and only the *new* quantities are reflected in
  Inventory — this is the part of this update most worth double-checking
  before you trust it with a real correction.
- Voiding a sale that already has a payment recorded against it — the
  payment record itself is untouched, only the sale's own Outstanding
  goes to zero, so confirm the customer ledger reads the way you expect
  afterward.
- Typing an existing customer's name with different capitalization or
  extra spacing (" ramesh traders" vs "Ramesh Traders") and confirming it
  matches rather than creating a duplicate.
- Recording a split payment across two or more of a customer's unpaid
  sales, then confirming each sale's own Outstanding dropped correctly
  and the dashboard's Pending figure reflects it — this is the most
  logic-heavy addition in this update and the one most worth a real
  dry run with fake data before you trust it with real collections.
- The custom autocomplete dropdown on an actual phone (both Android
  Chrome and iOS Safari, if you have both) — I built it specifically to
  fix a datalist rendering gap I can't personally verify from here.
- After running `setupSheets`, confirm `StockBalances` got backfilled
  with numbers that match what Inventory showed *before* this update —
  that's the real test that the migration worked, not just that it ran
  without an error.
