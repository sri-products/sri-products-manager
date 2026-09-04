-- ==========================================================================
-- Sri Products — Storefront Phase 2: delivery + flat-rate/slab shipping.
-- Run this in the Supabase SQL Editor AFTER schema.sql. Safe to run on
-- a database that already has orders in it — only adds columns/tables,
-- never drops data. Still no online payment: delivery orders are
-- pay-on-delivery, same "pay in person" model as pickup.
-- ==========================================================================

-- ---------- SETTINGS ----------
-- Business-configurable shipping rule, same key/value pattern as the
-- Business Manager's own Settings sheet. Free above a threshold, flat
-- fee below it — simplest model that's still normal for e-commerce.
-- No courier API integration yet; this is a number you charge, not a
-- real carrier rate lookup.

create table if not exists store_settings (
  key text primary key,
  value text not null
);

insert into store_settings (key, value) values
  ('delivery_fee', '49'),
  ('free_delivery_threshold', '999')
on conflict (key) do nothing;

create or replace view v_store_settings as
  select key, value from store_settings where key in ('delivery_fee', 'free_delivery_threshold');

grant select on v_store_settings to anon;

-- ---------- ORDERS: new columns ----------

alter table orders add column if not exists shipping_fee numeric(10,2) not null default 0;
alter table orders add column if not exists grand_total numeric(10,2) not null default 0;
alter table orders add column if not exists delivery_address_line1 text;
alter table orders add column if not exists delivery_address_line2 text;
alter table orders add column if not exists delivery_city text;
alter table orders add column if not exists delivery_pincode text;
alter table orders add column if not exists delivery_landmark text;

-- Backfill grand_total for any orders placed before this migration
-- (Phase 1 orders were pickup-only, so shipping_fee is correctly 0 for
-- all of them — grand_total is just their existing subtotal).
update orders set grand_total = subtotal where grand_total = 0;

-- ---------- create_order: replaced with a delivery-aware version ----------
-- Signature changed (new required/optional params), so the old
-- function must be dropped first — CREATE OR REPLACE can't change a
-- function's parameter list.

drop function if exists create_order(text, text, uuid, text, jsonb);

create or replace function create_order(
  p_fulfillment_type text,          -- 'pickup' or 'delivery'
  p_customer_name text,
  p_customer_phone text,
  p_pickup_location_id uuid,        -- required if fulfillment_type = 'pickup'
  p_delivery_address_line1 text,    -- required if fulfillment_type = 'delivery'
  p_delivery_address_line2 text,
  p_delivery_city text,
  p_delivery_pincode text,
  p_delivery_landmark text,
  p_notes text,
  p_items jsonb                     -- [{"item_id": "...", "quantity": 2}, ...]
) returns table (order_number text, order_id uuid, shipping_fee numeric, grand_total numeric)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_order_id uuid;
  v_order_number text;
  v_subtotal numeric(10,2) := 0;
  v_shipping_fee numeric(10,2) := 0;
  v_grand_total numeric(10,2) := 0;
  v_delivery_fee numeric(10,2);
  v_free_threshold numeric(10,2);
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric(10,2);
  v_price numeric(10,2);
  v_available numeric(10,2);
  v_name text;
  v_unit text;
  v_line_total numeric(10,2);
begin
  if p_fulfillment_type not in ('pickup', 'delivery') then
    raise exception 'Invalid fulfillment type.';
  end if;
  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Name is required.';
  end if;
  if p_customer_phone is null or trim(p_customer_phone) = '' then
    raise exception 'Phone number is required.';
  end if;
  if p_fulfillment_type = 'pickup' and p_pickup_location_id is null then
    raise exception 'Pickup location is required.';
  end if;
  if p_fulfillment_type = 'delivery' then
    if p_delivery_address_line1 is null or trim(p_delivery_address_line1) = '' then
      raise exception 'Delivery address is required.';
    end if;
    if p_delivery_city is null or trim(p_delivery_city) = '' then
      raise exception 'City is required.';
    end if;
    if p_delivery_pincode is null or p_delivery_pincode !~ '^[0-9]{6}$' then
      raise exception 'A valid 6-digit pincode is required.';
    end if;
  end if;
  if p_items is null or jsonb_array_length(p_items) = 0 then
    raise exception 'At least one item is required.';
  end if;

  insert into orders (
    fulfillment_type, customer_name, customer_phone, pickup_location_id,
    delivery_address_line1, delivery_address_line2, delivery_city, delivery_pincode, delivery_landmark,
    payment_method, notes
  )
  values (
    p_fulfillment_type, trim(p_customer_name), trim(p_customer_phone),
    case when p_fulfillment_type = 'pickup' then p_pickup_location_id else null end,
    p_delivery_address_line1, p_delivery_address_line2, p_delivery_city, p_delivery_pincode, p_delivery_landmark,
    case when p_fulfillment_type = 'delivery' then 'pay_on_delivery' else 'pay_on_pickup' end,
    p_notes
  )
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

  if p_fulfillment_type = 'delivery' then
    select coalesce(max(value::numeric), 49) into v_delivery_fee from store_settings where key = 'delivery_fee';
    select coalesce(max(value::numeric), 999) into v_free_threshold from store_settings where key = 'free_delivery_threshold';
    v_shipping_fee := case when v_subtotal >= v_free_threshold then 0 else v_delivery_fee end;
  end if;
  v_grand_total := v_subtotal + v_shipping_fee;

  update orders set subtotal = v_subtotal, shipping_fee = v_shipping_fee, grand_total = v_grand_total, updated_at = now()
    where id = v_order_id;

  return query select v_order_number, v_order_id, v_shipping_fee, v_grand_total;
end;
$$;

grant execute on function create_order(text, text, text, uuid, text, text, text, text, text, text, jsonb) to anon;

-- ---------- get_order_status: include delivery + totals ----------

drop function if exists get_order_status(text, text);

create or replace function get_order_status(p_order_number text, p_phone text)
returns table (
  order_number text,
  status text,
  payment_status text,
  fulfillment_type text,
  subtotal numeric,
  shipping_fee numeric,
  grand_total numeric,
  delivery_address_line1 text,
  delivery_address_line2 text,
  delivery_city text,
  delivery_pincode text,
  delivery_landmark text,
  created_at timestamptz,
  items jsonb
)
language sql
security definer
set search_path = public
as $$
  select o.order_number, o.status, o.payment_status, o.fulfillment_type,
    o.subtotal, o.shipping_fee, o.grand_total,
    o.delivery_address_line1, o.delivery_address_line2, o.delivery_city, o.delivery_pincode, o.delivery_landmark,
    o.created_at,
    (select jsonb_agg(jsonb_build_object('name', oi.item_name, 'quantity', oi.quantity, 'unit', oi.unit, 'lineTotal', oi.line_total))
     from order_items oi where oi.order_id = o.id)
  from orders o
  where o.order_number = p_order_number and o.customer_phone = p_phone;
$$;

grant execute on function get_order_status(text, text) to anon;
