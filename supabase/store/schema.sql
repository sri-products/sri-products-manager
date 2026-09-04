-- ==========================================================================
-- Sri Products — Storefront schema (Phase 1: catalog + cart + pickup +
-- pay-on-pickup). Run this in the Supabase SQL Editor once, on a fresh
-- project.
--
-- Design choices, so future-you (or the next person migrating the
-- Business Manager onto this same database) knows why:
--
-- 1. No Supabase Auth / customer accounts yet. Phase 1 is guest
--    checkout: name + phone captured directly on the order. B2B
--    account linking (tying an online order to an existing Customer
--    record from the Sheets/Business Manager side) is a later phase —
--    `legacy_customer_id` is here as a placeholder column for that.
--
-- 2. Public (anon) role gets READ access only to catalog/pricing/stock
--    via views, never the raw tables — and NO direct read/write access
--    to orders or order_items at all. All order creation/lookup goes
--    through SECURITY DEFINER functions below, so price and stock
--    checks always happen server-side against current data, never
--    trusting whatever the browser sends.
--
-- 3. Items/prices/stock use uuid primary keys (Postgres-native), with a
--    nullable `legacy_item_id` / `legacy_customer_id` text column to
--    map back to the existing Sheets ItemId/CustomerId (e.g. "ITM0004")
--    once/if the Business Manager migrates onto this same database.
-- ==========================================================================

-- ---------- CATALOG ----------

create table items (
  id uuid primary key default gen_random_uuid(),
  legacy_item_id text,                 -- e.g. 'ITM0004', once migrated from Sheets
  name text not null,
  description text,
  unit text not null,                  -- 'Litre', 'Kg', etc.
  type text,                           -- 'FinishedOil', 'CakeByProduct', etc.
  image_url text,
  active boolean not null default true,
  visible_online boolean not null default true,  -- lets you stock internal-only items
  created_at timestamptz not null default now()
);

create table price_history (
  id uuid primary key default gen_random_uuid(),
  item_id uuid not null references items(id) on delete cascade,
  effective_from date not null,
  price numeric(10,2) not null check (price >= 0),
  created_at timestamptz not null default now(),
  unique (item_id, effective_from)
);

-- Per-customer negotiated pricing — not used by Phase 1 (no accounts
-- yet), created now so the table exists before B2B accounts land.
create table customer_price_overrides (
  id uuid primary key default gen_random_uuid(),
  legacy_customer_id text not null,    -- e.g. 'CUS-00012'
  item_id uuid not null references items(id) on delete cascade,
  price numeric(10,2) not null check (price >= 0),
  created_at timestamptz not null default now(),
  unique (legacy_customer_id, item_id)
);

create table stock_balances (
  item_id uuid primary key references items(id) on delete cascade,
  balance numeric(10,2) not null default 0,
  reserved numeric(10,2) not null default 0,   -- held by pending unpaid orders
  updated_at timestamptz not null default now()
);

create table pickup_locations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  address text not null,
  hours text,
  active boolean not null default true
);

-- ---------- ORDERS ----------

create sequence order_number_seq start 1;

create or replace function next_order_number() returns text
language sql as $$
  select 'ORD-' || lpad(nextval('order_number_seq')::text, 6, '0');
$$;

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_number text not null unique default next_order_number(),
  legacy_customer_id text,             -- filled in once B2B accounts exist
  customer_name text not null,
  customer_phone text not null,
  fulfillment_type text not null default 'pickup' check (fulfillment_type in ('pickup', 'delivery')),
  pickup_location_id uuid references pickup_locations(id),
  status text not null default 'pending' check (status in ('pending', 'confirmed', 'ready', 'completed', 'cancelled')),
  payment_method text not null default 'pay_on_pickup' check (payment_method in ('pay_on_pickup', 'pay_on_delivery', 'online')),
  payment_status text not null default 'unpaid' check (payment_status in ('unpaid', 'paid', 'refunded')),
  subtotal numeric(10,2) not null default 0,
  notes text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table order_items (
  id uuid primary key default gen_random_uuid(),
  order_id uuid not null references orders(id) on delete cascade,
  item_id uuid not null references items(id),
  item_name text not null,             -- snapshot, so renaming a product later doesn't rewrite history
  unit text not null,
  quantity numeric(10,2) not null check (quantity > 0),
  unit_price numeric(10,2) not null check (unit_price >= 0),
  line_total numeric(10,2) not null
);

-- ---------- PUBLIC READ-ONLY VIEWS ----------
-- These are the only things the anon role can query directly. Current
-- price is computed on the fly (latest price_history row on/before
-- today) so the storefront never sees stale or full pricing history.

create view v_catalog as
select
  i.id,
  i.name,
  i.description,
  i.unit,
  i.type,
  i.image_url,
  (
    select ph.price from price_history ph
    where ph.item_id = i.id and ph.effective_from <= current_date
    order by ph.effective_from desc limit 1
  ) as price,
  greatest(coalesce(sb.balance, 0) - coalesce(sb.reserved, 0), 0) as available_qty
from items i
left join stock_balances sb on sb.item_id = i.id
where i.active = true and i.visible_online = true;

create view v_pickup_locations as
select id, name, address, hours from pickup_locations where active = true;

-- ---------- ORDER CREATION / LOOKUP (SECURITY DEFINER) ----------
-- These run with the privileges of the function owner, not the caller,
-- so they can safely read/write orders, order_items and stock_balances
-- even though anon has no direct grants on those tables. All validation
-- (price, availability) happens here against live data — the client
-- only ever sends item ids + quantities, never prices.

create or replace function create_order(
  p_customer_name text,
  p_customer_phone text,
  p_pickup_location_id uuid,
  p_notes text,
  p_items jsonb  -- [{"item_id": "...", "quantity": 2}, ...]
) returns table (order_number text, order_id uuid)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_subtotal numeric(10,2) := 0;
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric(10,2);
  v_price numeric(10,2);
  v_available numeric(10,2);
  v_name text;
  v_unit text;
  v_line_total numeric(10,2);
begin
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Phone number is required.';
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one item is required.';
  end if;

  insert into orders (customer_name, customer_phone, pickup_location_id, notes)
  values (trim(p_customer_name), trim(p_customer_phone), p_pickup_location_id, p_notes)
  returning id, orders.order_number into v_order_id, v_order_number;

  for v_line in select * from jsonb_array_elements(p_items) loop
    v_item_id := (v_line->>'item_id')::uuid;
    v_qty := (v_line->>'quantity')::numeric;

    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantity must be greater than zero.';
    end if;

    select i.name, i.unit into v_name, v_unit from items i where i.id = v_item_id and i.active and i.visible_online;
    if v_name is null then
      raise exception 'Item not found or not available: %', v_item_id;
    end if;

    select ph.price into v_price from price_history ph
      where ph.item_id = v_item_id and ph.effective_from <= current_date
      order by ph.effective_from desc limit 1;
    if v_price is null then
      raise exception 'No price set for %.', v_name;
    end if;

    select greatest(coalesce(sb.balance, 0) - coalesce(sb.reserved, 0), 0) into v_available
      from stock_balances sb where sb.item_id = v_item_id;
    if coalesce(v_available, 0) < v_qty then
      raise exception 'Not enough stock for %: requested %, only % available.', v_name, v_qty, coalesce(v_available, 0);
    end if;

    v_line_total := round(v_qty * v_price, 2);
    v_subtotal := v_subtotal + v_line_total;

    insert into order_items (order_id, item_id, item_name, unit, quantity, unit_price, line_total)
    values (v_order_id, v_item_id, v_name, v_unit, v_qty, v_price, v_line_total);

    update stock_balances set reserved = coalesce(reserved, 0) + v_qty, updated_at = now()
      where item_id = v_item_id;
    if not found then
      insert into stock_balances (item_id, balance, reserved) values (v_item_id, 0, v_qty);
    end if;
  end loop;

  update orders set subtotal = v_subtotal, updated_at = now() where id = v_order_id;

  return query select v_order_number, v_order_id;
end;
$$;

-- Guest order lookup: order number + phone, so a customer can check
-- status without an account. Deliberately returns nothing (not an
-- error) on a phone mismatch, rather than confirming which part was
-- wrong, so this can't be used to enumerate other people's orders by
-- guessing order numbers.
create or replace function get_order_status(p_order_number text, p_phone text)
returns table (
  order_number text,
  status text,
  payment_status text,
  subtotal numeric,
  created_at timestamptz,
  items jsonb
)
language sql
security definer
set search_path = public
as $$
  select o.order_number, o.status, o.payment_status, o.subtotal, o.created_at,
    (select jsonb_agg(jsonb_build_object('name', oi.item_name, 'quantity', oi.quantity, 'unit', oi.unit, 'lineTotal', oi.line_total))
     from order_items oi where oi.order_id = o.id)
  from orders o
  where o.order_number = p_order_number and o.customer_phone = p_phone;
$$;

-- Lets a guest cancel their own still-pending order and releases the
-- stock reservation. Anything already confirmed/ready needs a human
-- (call the shop) — deliberately not self-service past that point.
create or replace function cancel_order(p_order_number text, p_phone text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_status text;
begin
  select id, status into v_order_id, v_status from orders
    where order_number = p_order_number and customer_phone = p_phone;
  if v_order_id is null then
    raise exception 'Order not found.';
  end if;
  if v_status <> 'pending' then
    raise exception 'This order can no longer be cancelled online — please call the shop.';
  end if;

  update stock_balances sb set reserved = greatest(reserved - oi.quantity, 0), updated_at = now()
    from order_items oi where oi.order_id = v_order_id and sb.item_id = oi.item_id;

  update orders set status = 'cancelled', updated_at = now() where id = v_order_id;
  return true;
end;
$$;

-- ---------- ROW LEVEL SECURITY ----------
-- Enable RLS everywhere, then grant the anon role only what's listed
-- below. No policy = no access, which is the safe default for a
-- public-facing key.

alter table items enable row level security;
alter table price_history enable row level security;
alter table customer_price_overrides enable row level security;
alter table stock_balances enable row level security;
alter table pickup_locations enable row level security;
alter table orders enable row level security;
alter table order_items enable row level security;

-- Base tables: no policies for anon at all (catalog is exposed only
-- through the v_catalog / v_pickup_locations views below, which run as
-- the view owner). orders/order_items: no policies for anon at all —
-- every access goes through create_order / get_order_status /
-- cancel_order, which run as SECURITY DEFINER.

grant select on v_catalog, v_pickup_locations to anon;
grant execute on function create_order(text, text, uuid, text, jsonb) to anon;
grant execute on function get_order_status(text, text) to anon;
grant execute on function cancel_order(text, text) to anon;

-- ---------- SAMPLE DATA (delete or edit before going live) ----------

insert into pickup_locations (name, address, hours) values
  ('Sri Products — Main Counter', 'Replace with your real shop address', 'Mon–Sat, 9am–7pm');

insert into items (name, description, unit, type) values
  ('Groundnut Oil', 'Cold-pressed groundnut oil', 'Litre', 'FinishedOil'),
  ('Sesame Oil', 'Cold-pressed sesame oil', 'Litre', 'FinishedOil'),
  ('Oil Cake', 'By-product cake, sold by weight', 'Kg', 'CakeByProduct');

insert into price_history (item_id, effective_from, price)
  select id, current_date, case name
    when 'Groundnut Oil' then 220
    when 'Sesame Oil' then 320
    when 'Oil Cake' then 40
  end
  from items;

insert into stock_balances (item_id, balance)
  select id, 100 from items;
