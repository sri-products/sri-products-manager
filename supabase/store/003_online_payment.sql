-- ==========================================================================
-- Sri Products — Storefront Phase 3: online prepay (Razorpay).
-- Run this in the Supabase SQL Editor AFTER schema.sql and
-- 002_delivery.sql. Additive migration, safe on a database with real
-- orders already in it.
--
-- Payment confirmation must never be trusted from the browser alone —
-- a customer's browser saying "payment succeeded" isn't proof it did.
-- The actual trust boundary here is the Edge Functions (Phase 3's
-- other half, in supabase/functions/), which hold the Razorpay secret
-- key and the Supabase service_role key — neither of which exist in
-- any frontend file. This migration just adds the columns/functions
-- those Edge Functions need.
-- ==========================================================================

alter table orders add column if not exists razorpay_order_id text;
alter table orders add column if not exists razorpay_payment_id text;

create unique index if not exists orders_razorpay_order_id_idx
  on orders (razorpay_order_id) where razorpay_order_id is not null;

-- ---------- create_order: replaced with a payment-method-aware version ----------

drop function if exists create_order(text, text, text, uuid, text, text, text, text, text, text, jsonb);

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
  p_items jsonb,                    -- [{"item_id": "...", "quantity": 2}, ...]
  p_pay_online boolean default false
) returns table (order_number text, order_id uuid, shipping_fee numeric, grand_total numeric, payment_method text)
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
  v_payment_method text;
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

  v_payment_method := case
    when p_pay_online then 'online'
    when p_fulfillment_type = 'delivery' then 'pay_on_delivery'
    else 'pay_on_pickup'
  end;

  insert into orders (
    fulfillment_type, customer_name, customer_phone, pickup_location_id,
    delivery_address_line1, delivery_address_line2, delivery_city, delivery_pincode, delivery_landmark,
    payment_method, notes
  )
  values (
    p_fulfillment_type, trim(p_customer_name), trim(p_customer_phone),
    case when p_fulfillment_type = 'pickup' then p_pickup_location_id else null end,
    p_delivery_address_line1, p_delivery_address_line2, p_delivery_city, p_delivery_pincode, p_delivery_landmark,
    v_payment_method, p_notes
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

  return query select v_order_number, v_order_id, v_shipping_fee, v_grand_total, v_payment_method;
end;
$$;

grant execute on function create_order(text, text, text, uuid, text, text, text, text, text, text, jsonb, boolean) to anon;

-- ---------- get_order_status: include payment method + razorpay ids ----------

drop function if exists get_order_status(text, text);

create or replace function get_order_status(p_order_number text, p_phone text)
returns table (
  order_number text,
  status text,
  payment_status text,
  payment_method text,
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
  select o.order_number, o.status, o.payment_status, o.payment_method, o.fulfillment_type,
    o.subtotal, o.shipping_fee, o.grand_total,
    o.delivery_address_line1, o.delivery_address_line2, o.delivery_city, o.delivery_pincode, o.delivery_landmark,
    o.created_at,
    (select jsonb_agg(jsonb_build_object('name', oi.item_name, 'quantity', oi.quantity, 'unit', oi.unit, 'lineTotal', oi.line_total))
     from order_items oi where oi.order_id = o.id)
  from orders o
  where o.order_number = p_order_number and o.customer_phone = p_phone;
$$;

grant execute on function get_order_status(text, text) to anon;

-- ---------- mark_order_paid ----------
-- Called only by the create-razorpay-order/verify-payment/webhook Edge
-- Functions (via the service_role key, which bypasses RLS/grants
-- entirely) — deliberately NOT granted to anon or authenticated, so
-- there is no path for a browser to call this directly and mark its
-- own order paid without a verified Razorpay signature.

create or replace function mark_order_paid(
  p_order_number text,
  p_razorpay_order_id text,
  p_razorpay_payment_id text
) returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  v_id uuid;
  v_status text;
begin
  select id, status into v_id, v_status from orders where order_number = p_order_number;
  if v_id is null then
    return false;
  end if;
  update orders set
    payment_status = 'paid',
    razorpay_order_id = coalesce(p_razorpay_order_id, razorpay_order_id),
    razorpay_payment_id = p_razorpay_payment_id,
    status = case when status = 'pending' then 'confirmed' else status end,
    updated_at = now()
  where id = v_id;
  return true;
end;
$$;

-- ---------- release_expired_online_orders ----------
-- Manual recovery tool (like the Business Manager's rebuildStockBalances)
-- for online orders where the customer opened Razorpay Checkout, never
-- completed or abandoned it, and left stock reserved indefinitely. Not
-- exposed to anon. Run it yourself from the SQL Editor periodically, or
-- schedule it with Supabase's pg_cron extension — see store/README.md.

create or replace function release_expired_online_orders(p_older_than_minutes integer default 30)
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  v_ids uuid[];
begin
  select array_agg(id) into v_ids from orders
    where payment_method = 'online' and payment_status = 'unpaid' and status = 'pending'
      and created_at < now() - (p_older_than_minutes || ' minutes')::interval;

  if v_ids is null then
    return 0;
  end if;

  update stock_balances sb set reserved = greatest(reserved - oi.quantity, 0), updated_at = now()
    from order_items oi
    where sb.item_id = oi.item_id and oi.order_id = any(v_ids);

  update orders set status = 'cancelled', updated_at = now() where id = any(v_ids);

  return array_length(v_ids, 1);
end;
$$;
