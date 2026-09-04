-- ==========================================================================
-- Sri Products — Business Manager migration onto Supabase.
-- Domain: Customers, Items, Price book, Bottle adjustments, Stock
-- (current stock / history / manual adjustments), Dashboard.
--
-- Run in the SQL Editor AFTER schema.sql, 002_delivery.sql,
-- 003_online_payment.sql, and staff/004_staff_foundation.sql. Safe to
-- run alongside (before or after) the Sales+Payments and
-- Quotations+Production staff migrations — this file only reads
-- sales/payments (tables already created by 004), it never writes
-- them.
--
-- ---------- ITEM ID DESIGN DECISION (read this before touching
-- anything item-related in this file) ----------
--
-- The shared `items` table (schema.sql) has a uuid primary key `id`
-- and a nullable `legacy_item_id` text column intended for imported
-- Sheets-era IDs like 'ITM0004'. Since this migration happens BEFORE
-- any real Sheets data import, there are no existing rows with
-- `legacy_item_id` set, and every item created from `create_item`
-- onward only ever exists in Postgres — it never had a Sheets ID to
-- begin with.
--
-- app.js treats "ItemId" purely as an opaque string key (it's used to
-- look items up in arrays, build URL fragments like
-- #/inventory/<itemId>, and as a jsonb payload field) — it is never
-- parsed, padded, or format-checked anywhere in app.js. That means the
-- simplest correct choice is to expose the item's uuid `id`, cast to
-- text, AS "ItemId" in every JSON shape below (list_items,
-- get_current_prices, get_current_stock, stock movement history,
-- etc.), and never invent a new fake padded scheme (e.g. 'ITM0001')
-- for new rows — that would just be complexity with no payoff, since
-- nothing downstream cares what the string looks like. `legacy_item_id`
-- stays purely a historical reference column for a future data import;
-- it is never read or written by any function in this file.
--
-- The same reasoning applies to price_history rows (no legacy id
-- column at all — PriceId is just price_history.id::text) and
-- bottle_adjustments (which already has its own generated
-- `adjustment_id` text column from 004, so that one's used as-is,
-- matching Code.gs's AdjustmentId).
--
-- Customers are different: `customers.customer_id` (from 004) is a
-- real generated human-readable id ('CUS-00001', via next_id()) that
-- IS the CustomerId app.js already expects — no uuid-as-text needed
-- there.
-- ==========================================================================

-- price_history (schema.sql) predates staff auth entirely and has no
-- CreatedBy column, but Code.gs's PriceHistory sheet does (populated
-- with user.name on addPrice). Additive column, same pattern 004 used
-- to add items.tax_rate — safe on a table the storefront already
-- reads/writes, since the storefront never looks at this column.
alter table price_history add column if not exists created_by text;

-- ---------- CUSTOMERS ----------

-- Case-insensitive substring match on name, same as Code.gs's
-- listCustomers(search). PascalCase output mirrors the old Customers
-- sheet columns exactly.
create or replace function list_customers(p_search text default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'CustomerId', c.customer_id,
      'Name', c.name,
      'Active', c.active,
      'CreatedDate', c.created_at,
      'CreatedBy', c.created_by,
      'LastModifiedDate', c.last_modified_at,
      'LastModifiedBy', c.last_modified_by
    ) order by c.name)
    from customers c
    where p_search is null or trim(p_search) = '' or c.name ilike '%' || p_search || '%'
  ), '[]'::jsonb);
end;
$$;

create or replace function create_customer(p_name text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_customer_id text;
  v_now timestamptz := now();
  v_row customers;
begin
  v_staff := require_staff();
  if p_name is null or trim(p_name) = '' then
    raise exception 'Customer name is required.';
  end if;

  v_customer_id := next_id(coalesce((get_settings()->>'customerNumberPrefix'), 'CUS-'), 5);

  insert into customers (customer_id, name, active, created_at, created_by, last_modified_at, last_modified_by)
  values (v_customer_id, trim(p_name), true, v_now, v_staff.name, v_now, v_staff.name)
  returning * into v_row;

  return jsonb_build_object(
    'CustomerId', v_row.customer_id,
    'Name', v_row.name,
    'Active', v_row.active,
    'CreatedDate', v_row.created_at,
    'CreatedBy', v_row.created_by,
    'LastModifiedDate', v_row.last_modified_at,
    'LastModifiedBy', v_row.last_modified_by
  );
end;
$$;

-- Mirrors Code.gs's getCustomerLedger exactly: totals from ALL sales
-- (non-Voided only for totalSales) and ALL payments for this
-- customer, plus the raw row lists themselves (used by the UI to list
-- sales/payments on the customer detail screen and to build payment
-- allocation pickers). Sales/Payments rows are translated to the same
-- PascalCase shape the Sales/Payments domain's own list functions use,
-- so app.js's `s.SaleId`/`s.Status`/`p.PaymentId` etc. keep working
-- regardless of which screen loaded them.
create or replace function get_customer_ledger(p_customer_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_customer_pk uuid;
  v_total_sales numeric := 0;
  v_total_payments numeric := 0;
  v_sales jsonb;
  v_payments jsonb;
begin
  perform require_staff();

  select id into v_customer_pk from customers where customer_id = p_customer_id;
  if v_customer_pk is null then
    raise exception 'Customer not found.';
  end if;

  select coalesce(sum(s.grand_total), 0) into v_total_sales
    from sales s where s.customer_id = v_customer_pk and s.status <> 'Voided';

  select coalesce(sum(p.amount), 0) into v_total_payments
    from payments p where p.customer_id = v_customer_pk;

  select coalesce(jsonb_agg(jsonb_build_object(
      'SaleId', s.sale_id,
      'SaleDate', s.sale_date,
      'CustomerId', p_customer_id,
      'Subtotal', s.subtotal,
      'TaxAmount', s.tax_amount,
      'GrandTotal', s.grand_total,
      'AmountReceived', s.amount_received,
      'Outstanding', s.outstanding,
      'GstEnabled', s.gst_enabled,
      'QuotationRef', s.quotation_ref,
      'Status', s.status,
      'VoidReason', s.void_reason,
      'CreatedBy', s.created_by,
      'CreatedDate', s.created_at,
      'LastModifiedBy', s.last_modified_by,
      'LastModifiedDate', s.last_modified_at
    ) order by s.sale_date desc, s.created_at desc), '[]'::jsonb)
    into v_sales
    from sales s where s.customer_id = v_customer_pk;

  select coalesce(jsonb_agg(jsonb_build_object(
      'PaymentId', p.payment_id,
      'CustomerId', p_customer_id,
      'SaleId', p.sale_id,
      'Amount', p.amount,
      'PaymentDate', p.payment_date,
      'Method', p.method,
      'Notes', p.notes,
      'CreatedBy', p.created_by,
      'CreatedDate', p.created_at
    ) order by p.payment_date desc, p.created_at desc), '[]'::jsonb)
    into v_payments
    from payments p where p.customer_id = v_customer_pk;

  return jsonb_build_object(
    'totalSales', round(v_total_sales::numeric, 2),
    'totalPayments', round(v_total_payments::numeric, 2),
    'outstanding', round((v_total_sales - v_total_payments)::numeric, 2),
    'sales', v_sales,
    'payments', v_payments
  );
end;
$$;

-- ---------- ITEMS ----------

create or replace function list_items(p_include_inactive boolean default false) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'ItemId', i.id::text,
      'Name', i.name,
      'Type', i.type,
      'Unit', i.unit,
      'TaxRate', i.tax_rate,
      'Active', i.active,
      'CreatedDate', i.created_at
    ) order by i.name)
    from items i
    where p_include_inactive or i.active
  ), '[]'::jsonb);
end;
$$;

create or replace function create_item(p_item jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row items;
begin
  perform require_admin();
  if coalesce(p_item->>'name', '') = '' or coalesce(p_item->>'type', '') = '' or coalesce(p_item->>'unit', '') = '' then
    raise exception 'Item name, type, and unit are required.';
  end if;

  -- visible_online defaults to true on the `items` table (it was
  -- designed for the public storefront, which only ever creates
  -- items meant to be sold). Staff-created items must NOT inherit
  -- that default — a RawMaterial item (or any internal-only product)
  -- would otherwise silently appear for sale on the public storefront
  -- the moment it's created here. There's no "show in storefront"
  -- toggle in the Business Manager UI yet, so this stays false until
  -- someone flips it directly in Supabase, deliberately, later.
  insert into items (name, type, unit, tax_rate, active, visible_online)
  values (p_item->>'name', p_item->>'type', p_item->>'unit', coalesce((p_item->>'taxRate')::numeric, 0), true, false)
  returning * into v_row;

  return jsonb_build_object(
    'ItemId', v_row.id::text,
    'Name', v_row.name,
    'Type', v_row.type,
    'Unit', v_row.unit,
    'TaxRate', v_row.tax_rate,
    'Active', v_row.active,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function update_item(p_item_id text, p_updates jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row items;
begin
  perform require_admin();
  select * into v_row from items where id = p_item_id::uuid;
  if v_row is null then
    raise exception 'Item not found.';
  end if;

  update items set
    name = case when p_updates ? 'name' then p_updates->>'name' else name end,
    type = case when p_updates ? 'type' then p_updates->>'type' else type end,
    unit = case when p_updates ? 'unit' then p_updates->>'unit' else unit end,
    tax_rate = case when p_updates ? 'taxRate' then (p_updates->>'taxRate')::numeric else tax_rate end
  where id = v_row.id
  returning * into v_row;

  return jsonb_build_object(
    'ItemId', v_row.id::text,
    'Name', v_row.name,
    'Type', v_row.type,
    'Unit', v_row.unit,
    'TaxRate', v_row.tax_rate,
    'Active', v_row.active,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function set_item_active(p_item_id text, p_active boolean) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row items;
begin
  perform require_admin();
  update items set active = coalesce(p_active, false) where id = p_item_id::uuid returning * into v_row;
  if v_row is null then
    raise exception 'Item not found.';
  end if;

  return jsonb_build_object(
    'ItemId', v_row.id::text,
    'Name', v_row.name,
    'Type', v_row.type,
    'Unit', v_row.unit,
    'TaxRate', v_row.tax_rate,
    'Active', v_row.active,
    'CreatedDate', v_row.created_at
  );
end;
$$;

-- ---------- PRICE BOOK ----------

create or replace function list_prices(p_item_id text default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'PriceId', p.id::text,
      'ItemId', p.item_id::text,
      'EffectiveFrom', p.effective_from,
      'Price', p.price,
      'CreatedBy', p.created_by,
      'CreatedDate', p.created_at
    ) order by p.effective_from desc)
    from price_history p
    where p_item_id is null or p.item_id = p_item_id::uuid
  ), '[]'::jsonb);
end;
$$;

-- One row per active item: its latest price on/before today. For list
-- views — camelCase shape, deliberately different from list_prices's
-- PascalCase, matching Code.gs's getCurrentPrices() exactly.
create or replace function get_current_prices() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'itemId', i.id::text,
      'name', i.name,
      'unit', i.unit,
      'currentPrice', latest.price,
      'effectiveFrom', latest.effective_from
    ) order by i.name)
    from items i
    left join lateral (
      select ph.price, ph.effective_from
      from price_history ph
      where ph.item_id = i.id and ph.effective_from <= current_date
      order by ph.effective_from desc
      limit 1
    ) latest on true
    where i.active
  ), '[]'::jsonb);
end;
$$;

create or replace function add_price(p_item_id text, p_effective_from date, p_price numeric) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_row price_history;
  v_dupe uuid;
begin
  v_staff := require_admin();

  select id into v_dupe from price_history where item_id = p_item_id::uuid and effective_from = p_effective_from;
  if v_dupe is not null then
    raise exception 'A price for this item is already set for that Effective From date. Edit that entry instead.';
  end if;

  insert into price_history (item_id, effective_from, price, created_by)
  values (p_item_id::uuid, p_effective_from, p_price, v_staff.name)
  returning * into v_row;

  return jsonb_build_object(
    'PriceId', v_row.id::text,
    'ItemId', v_row.item_id::text,
    'EffectiveFrom', v_row.effective_from,
    'Price', v_row.price,
    'CreatedBy', v_row.created_by,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function update_price(p_price_id text, p_effective_from date, p_price numeric) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row price_history;
  v_dupe uuid;
begin
  perform require_admin();

  select * into v_row from price_history where id = p_price_id::uuid;
  if v_row is null then
    raise exception 'Price entry not found.';
  end if;

  select id into v_dupe from price_history
    where id <> v_row.id and item_id = v_row.item_id and effective_from = p_effective_from;
  if v_dupe is not null then
    raise exception 'Another price entry already exists for that date.';
  end if;

  update price_history set effective_from = p_effective_from, price = p_price
    where id = v_row.id returning * into v_row;

  return jsonb_build_object(
    'PriceId', v_row.id::text,
    'ItemId', v_row.item_id::text,
    'EffectiveFrom', v_row.effective_from,
    'Price', v_row.price,
    'CreatedBy', v_row.created_by,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function delete_price(p_price_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_found uuid;
begin
  perform require_admin();
  delete from price_history where id = p_price_id::uuid returning id into v_found;
  if v_found is null then
    raise exception 'Price entry not found.';
  end if;
  return jsonb_build_object('deleted', true);
end;
$$;

-- Internal helper (not exposed to the frontend). Other domains'
-- functions (Sales, Quotations) call this too — if they've each also
-- defined a copy, CREATE OR REPLACE just takes whichever runs last,
-- which is fine since the logic mirrors Code.gs's getEffectivePrice()
-- exactly either way.
create or replace function get_effective_price(p_item_id uuid, p_on_date date) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price numeric;
begin
  select ph.price into v_price
    from price_history ph
    where ph.item_id = p_item_id and ph.effective_from <= p_on_date
    order by ph.effective_from desc
    limit 1;
  if v_price is null then
    raise exception 'No price set for this item on or before %.', to_char(p_on_date, 'YYYY-MM-DD');
  end if;
  return v_price;
end;
$$;

-- ---------- BOTTLE ADJUSTMENTS ----------

create or replace function list_bottle_adjustments(p_item_id text default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'AdjustmentId', b.adjustment_id,
      'ItemId', b.item_id::text,
      'EffectiveFrom', b.effective_from,
      'Amount', b.amount,
      'CreatedBy', b.created_by,
      'CreatedDate', b.created_at
    ) order by b.effective_from desc)
    from bottle_adjustments b
    where p_item_id is null or b.item_id = p_item_id::uuid
  ), '[]'::jsonb);
end;
$$;

create or replace function get_current_bottle_adjustments() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'itemId', i.id::text,
      'name', i.name,
      'unit', i.unit,
      'currentAmount', latest.amount,
      'effectiveFrom', latest.effective_from
    ) order by i.name)
    from items i
    left join lateral (
      select b.amount, b.effective_from
      from bottle_adjustments b
      where b.item_id = i.id and b.effective_from <= current_date
      order by b.effective_from desc
      limit 1
    ) latest on true
    where i.active
  ), '[]'::jsonb);
end;
$$;

create or replace function add_bottle_adjustment(p_item_id text, p_effective_from date, p_amount numeric) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_row bottle_adjustments;
  v_dupe uuid;
begin
  v_staff := require_admin();

  select id into v_dupe from bottle_adjustments where item_id = p_item_id::uuid and effective_from = p_effective_from;
  if v_dupe is not null then
    raise exception 'A bottle adjustment for this item is already set for that Effective From date.';
  end if;

  insert into bottle_adjustments (adjustment_id, item_id, effective_from, amount, created_by)
  values (next_id('BTL', 5), p_item_id::uuid, p_effective_from, p_amount, v_staff.name)
  returning * into v_row;

  return jsonb_build_object(
    'AdjustmentId', v_row.adjustment_id,
    'ItemId', v_row.item_id::text,
    'EffectiveFrom', v_row.effective_from,
    'Amount', v_row.amount,
    'CreatedBy', v_row.created_by,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function update_bottle_adjustment(p_adjustment_id text, p_effective_from date, p_amount numeric) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_row bottle_adjustments;
  v_dupe uuid;
begin
  perform require_admin();

  select * into v_row from bottle_adjustments where adjustment_id = p_adjustment_id;
  if v_row is null then
    raise exception 'Adjustment entry not found.';
  end if;

  select id into v_dupe from bottle_adjustments
    where id <> v_row.id and item_id = v_row.item_id and effective_from = p_effective_from;
  if v_dupe is not null then
    raise exception 'Another adjustment entry already exists for that date.';
  end if;

  update bottle_adjustments set effective_from = p_effective_from, amount = p_amount
    where id = v_row.id returning * into v_row;

  return jsonb_build_object(
    'AdjustmentId', v_row.adjustment_id,
    'ItemId', v_row.item_id::text,
    'EffectiveFrom', v_row.effective_from,
    'Amount', v_row.amount,
    'CreatedBy', v_row.created_by,
    'CreatedDate', v_row.created_at
  );
end;
$$;

create or replace function delete_bottle_adjustment(p_adjustment_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_found uuid;
begin
  perform require_admin();
  delete from bottle_adjustments where adjustment_id = p_adjustment_id returning id into v_found;
  if v_found is null then
    raise exception 'Adjustment entry not found.';
  end if;
  return jsonb_build_object('deleted', true);
end;
$$;

-- Internal helper — 0 (not an error) when nothing applies, matching
-- Code.gs's getEffectiveBottleAdjustment() exactly (unlike prices,
-- "no adjustment set" is a perfectly normal, common case).
create or replace function get_effective_bottle_adjustment(p_item_id uuid, p_on_date date) returns numeric
language sql
security definer
set search_path = public
as $$
  select coalesce((
    select b.amount
    from bottle_adjustments b
    where b.item_id = p_item_id and b.effective_from <= p_on_date
    order by b.effective_from desc
    limit 1
  ), 0);
$$;

-- ---------- STOCK ----------
-- current_stock reads stock_balances.balance directly, same as
-- Code.gs's getCurrentStock() reading the StockBalances sheet — a
-- running total kept in sync by record_stock_movement/
-- adjust_stock_balance rather than summed from the ledger on every
-- call. Deliberately NOT balance - reserved: "reserved" (stock held by
-- pending unpaid online orders) is a storefront-only concept that
-- doesn't exist in Code.gs's model at all — the Business Manager's
-- idea of "current stock" is the raw balance, full stop.

create or replace function get_current_stock() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'itemId', i.id::text,
      'name', i.name,
      'unit', i.unit,
      'type', i.type,
      'active', i.active,
      'currentStock', round(coalesce(sb.balance, 0)::numeric, 2)
    ) order by i.name)
    from items i
    left join stock_balances sb on sb.item_id = i.id
  ), '[]'::jsonb);
end;
$$;

create or replace function get_stock_movement_history(p_item_id text default null) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform require_staff();
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'MovementId', m.movement_id,
      'Date', m.occurred_at,
      'ItemId', m.item_id::text,
      'Quantity', m.quantity,
      'Unit', m.unit,
      'MovementType', m.movement_type,
      'ReferenceType', m.reference_type,
      'ReferenceId', m.reference_id,
      'Notes', m.notes,
      'CreatedBy', m.created_by,
      'CreatedDate', m.created_at
    ) order by m.occurred_at desc)
    from stock_movements m
    where p_item_id is null or m.item_id = p_item_id::uuid
  ), '[]'::jsonb);
end;
$$;

create or replace function create_stock_adjustment(p_item_id text, p_quantity numeric, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_item items;
  v_movement_id text;
begin
  v_staff := require_admin();
  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required for stock adjustments.';
  end if;

  select * into v_item from items where id = p_item_id::uuid;
  if v_item is null then
    raise exception 'Item not found.';
  end if;

  v_movement_id := record_stock_movement(v_item.id, p_quantity, v_item.unit, 'StockAdjustment', 'Manual', '', p_reason, v_staff.name);

  return (
    select jsonb_build_object(
      'MovementId', m.movement_id,
      'Date', m.occurred_at,
      'ItemId', m.item_id::text,
      'Quantity', m.quantity,
      'Unit', m.unit,
      'MovementType', m.movement_type,
      'ReferenceType', m.reference_type,
      'ReferenceId', m.reference_id,
      'Notes', m.notes,
      'CreatedBy', m.created_by,
      'CreatedDate', m.created_at
    )
    from stock_movements m where m.movement_id = v_movement_id
  );
end;
$$;

-- Reverses a manual stock adjustment with an offsetting entry — the
-- ledger itself is never mutated or removed, only added to. Mirrors
-- Code.gs's reverseStockAdjustment() exactly, including restricting
-- this to StockAdjustment-type movements only (sales/production have
-- their own Void/Delete flows that reverse stock).
create or replace function reverse_stock_adjustment(p_movement_id text, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_row stock_movements;
  v_new_movement_id text;
begin
  v_staff := require_admin();

  select * into v_row from stock_movements where movement_id = p_movement_id;
  if v_row is null then
    raise exception 'Movement not found.';
  end if;
  if v_row.movement_type <> 'StockAdjustment' then
    raise exception 'Only manual stock adjustments can be reversed here — sales and production are reversed via their own Void/Delete.';
  end if;

  v_new_movement_id := record_stock_movement(
    v_row.item_id,
    -v_row.quantity,
    v_row.unit,
    'StockAdjustment',
    'Manual',
    '',
    'Reversal of ' || p_movement_id || (case when p_reason is not null and trim(p_reason) <> '' then ': ' || p_reason else '' end),
    v_staff.name
  );

  return (
    select jsonb_build_object(
      'MovementId', m.movement_id,
      'Date', m.occurred_at,
      'ItemId', m.item_id::text,
      'Quantity', m.quantity,
      'Unit', m.unit,
      'MovementType', m.movement_type,
      'ReferenceType', m.reference_type,
      'ReferenceId', m.reference_id,
      'Notes', m.notes,
      'CreatedBy', m.created_by,
      'CreatedDate', m.created_at
    )
    from stock_movements m where m.movement_id = v_new_movement_id
  );
end;
$$;

-- ---------- DASHBOARD ----------

create or replace function get_dashboard() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_today date := current_date;
  v_month_start date := date_trunc('month', current_date)::date;
  v_today_sales_total numeric := 0;
  v_today_sales_count int := 0;
  v_today_payments_total numeric := 0;
  v_month_sales_total numeric := 0;
  v_pending_receivable numeric := 0;
  v_credits_owed numeric := 0;
  v_current_stock jsonb;
  v_recent_sales jsonb;
  v_recent_payments jsonb;
  v_product_summary jsonb;
begin
  perform require_staff();

  select coalesce(sum(s.grand_total), 0), count(*)
    into v_today_sales_total, v_today_sales_count
    from sales s where s.status <> 'Voided' and s.sale_date >= v_today;

  select coalesce(sum(s.grand_total), 0) into v_month_sales_total
    from sales s where s.status <> 'Voided' and s.sale_date >= v_month_start;

  select coalesce(sum(p.amount), 0) into v_today_payments_total
    from payments p where p.payment_date >= v_today;

  -- Split net outstanding into what's owed TO you vs. credit you owe
  -- BACK (from an overpayment) — netting them into one number would
  -- hide the second case entirely, same reasoning as Code.gs.
  select
      coalesce(sum(greatest(0, s.outstanding)), 0),
      coalesce(sum(greatest(0, -s.outstanding)), 0)
    into v_pending_receivable, v_credits_owed
    from sales s where s.status <> 'Voided';

  v_current_stock := get_current_stock();

  -- Recent sales: same enrichment Code.gs's enrichSalesWithDetails()
  -- does (customerName + a per-line item summary) — duplicated here
  -- rather than calling the Sales domain's own list function, so this
  -- file has no load-order/definition dependency on 005/006.
  select coalesce(jsonb_agg(sale_json), '[]'::jsonb) into v_recent_sales
  from (
    select jsonb_build_object(
      'SaleId', s.sale_id,
      'SaleDate', s.sale_date,
      'CustomerId', c.customer_id,
      'Subtotal', s.subtotal,
      'TaxAmount', s.tax_amount,
      'GrandTotal', s.grand_total,
      'AmountReceived', s.amount_received,
      'Outstanding', s.outstanding,
      'GstEnabled', s.gst_enabled,
      'QuotationRef', s.quotation_ref,
      'Status', s.status,
      'VoidReason', s.void_reason,
      'CreatedBy', s.created_by,
      'CreatedDate', s.created_at,
      'LastModifiedBy', s.last_modified_by,
      'LastModifiedDate', s.last_modified_at,
      'customerName', c.name,
      'items', (
        select coalesce(jsonb_agg(jsonb_build_object(
            'itemName', coalesce(i.name, si.item_id::text),
            'quantity', si.quantity,
            'unit', si.unit
          )), '[]'::jsonb)
        from sale_items si
        left join items i on i.id = si.item_id
        where si.sale_id = s.sale_id
      )
    ) as sale_json
    from sales s
    join customers c on c.id = s.customer_id
    order by s.created_at desc
    limit 5
  ) recent;

  select coalesce(jsonb_agg(jsonb_build_object(
      'PaymentId', p.payment_id,
      'CustomerId', c.customer_id,
      'SaleId', p.sale_id,
      'Amount', p.amount,
      'PaymentDate', p.payment_date,
      'Method', p.method,
      'Notes', p.notes,
      'CreatedBy', p.created_by,
      'CreatedDate', p.created_at
    )), '[]'::jsonb) into v_recent_payments
  from (
    select * from payments order by created_at desc limit 5
  ) p
  join customers c on c.id = p.customer_id;

  -- Finished-oil / cake-by-product quantities sold this month, per
  -- product — from sale_items on active (non-voided) sales dated this
  -- month, only products with quantitySold > 0.
  select coalesce(jsonb_agg(jsonb_build_object(
      'itemId', i.id::text,
      'name', i.name,
      'type', i.type,
      'unit', i.unit,
      'quantitySold', round(coalesce(qty.total, 0)::numeric, 2)
    ) order by i.name), '[]'::jsonb) into v_product_summary
  from items i
  join lateral (
    select sum(si.quantity) as total
    from sale_items si
    join sales s on s.sale_id = si.sale_id
    where si.item_id = i.id and s.status <> 'Voided' and s.sale_date >= v_month_start
  ) qty on true
  where i.type in ('FinishedOil', 'CakeByProduct') and coalesce(qty.total, 0) > 0;

  return jsonb_build_object(
    'todaySalesTotal', round(v_today_sales_total::numeric, 2),
    'todaySalesCount', v_today_sales_count,
    'todayPaymentsTotal', round(v_today_payments_total::numeric, 2),
    'monthSalesTotal', round(v_month_sales_total::numeric, 2),
    'pendingReceivable', round(v_pending_receivable::numeric, 2),
    'creditsOwed', round(v_credits_owed::numeric, 2),
    'currentStock', v_current_stock,
    'recentSales', v_recent_sales,
    'recentPayments', v_recent_payments,
    'productSummary', v_product_summary
  );
end;
$$;

-- ---------- GRANTS ----------
-- Only the functions app.js actually calls (via api.js) go to
-- `authenticated`. Internal helpers (get_effective_price,
-- get_effective_bottle_adjustment) are deliberately NOT granted here —
-- they're called from other SECURITY DEFINER functions (this file's
-- and the Sales/Quotations domain's), never directly from the client.

grant execute on function list_customers(text) to authenticated;
grant execute on function create_customer(text) to authenticated;
grant execute on function get_customer_ledger(text) to authenticated;

grant execute on function list_items(boolean) to authenticated;
grant execute on function create_item(jsonb) to authenticated;
grant execute on function update_item(text, jsonb) to authenticated;
grant execute on function set_item_active(text, boolean) to authenticated;

grant execute on function list_prices(text) to authenticated;
grant execute on function get_current_prices() to authenticated;
grant execute on function add_price(text, date, numeric) to authenticated;
grant execute on function update_price(text, date, numeric) to authenticated;
grant execute on function delete_price(text) to authenticated;

grant execute on function list_bottle_adjustments(text) to authenticated;
grant execute on function get_current_bottle_adjustments() to authenticated;
grant execute on function add_bottle_adjustment(text, date, numeric) to authenticated;
grant execute on function update_bottle_adjustment(text, date, numeric) to authenticated;
grant execute on function delete_bottle_adjustment(text) to authenticated;

grant execute on function get_current_stock() to authenticated;
grant execute on function get_stock_movement_history(text) to authenticated;
grant execute on function create_stock_adjustment(text, numeric, text) to authenticated;
grant execute on function reverse_stock_adjustment(text, text) to authenticated;

grant execute on function get_dashboard() to authenticated;
