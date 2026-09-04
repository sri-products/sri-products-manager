-- ==========================================================================
-- Sri Products — Business Manager migration onto Supabase (Phase 5,
-- Sales + Payments domain). Run in the SQL Editor AFTER
-- 004_staff_foundation.sql. Ports Code.gs's createSale/updateSale/
-- voidSale/enrichSalesWithDetails/listSales/getSaleDetail/
-- recordPayment/markSaleAsPaid/listPayments one-for-one, including the
-- getEffectivePrice/getEffectiveBottleAdjustment price-lookup rules,
-- onto this schema. app.js is not changing as part of this migration,
-- so every jsonb key name/casing below is deliberately copied from
-- what Code.gs actually returned (PascalCase Sheet-style columns for
-- row objects, camelCase for the extra "enrichment" fields Code.gs
-- bolted on) — do not "clean up" the casing without re-checking
-- js/app.js's Api.call() call sites first.
--
-- Quotations and Production are owned by other agents working the
-- same migration in parallel; this file only touches sales/sale_items/
-- payments/customers/stock. resolve_customer() below is written
-- generically (not "resolve_sale_customer") specifically because
-- Quotations needs the exact same customerId/customerName resolution
-- logic Code.gs's resolveCustomer() provided to both domains — reuse
-- this function from the Quotations file rather than duplicating it,
-- if this file runs first; duplicate it under a different name if
-- Quotations' migration file must be independent/run-order-agnostic.
-- ==========================================================================

-- ---------- CUSTOMER RESOLUTION ----------
-- Mirrors Code.gs's resolveCustomer()/createCustomer(): match on an
-- explicit id first, else an exact (trimmed, case-insensitive) name
-- match, else create a new customer. Deliberately no fuzzy matching —
-- silently merging two different customers because their names are
-- similar would corrupt the ledger.

create or replace function resolve_customer(p_customer_id text, p_customer_name text) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_id uuid;
  v_name text;
  v_customer_number text;
begin
  v_staff := require_staff();

  if p_customer_id is not null and trim(p_customer_id) <> '' then
    select id into v_id from customers where customer_id = p_customer_id;
    if v_id is null then
      raise exception 'Customer not found.';
    end if;
    return v_id;
  end if;

  if p_customer_name is null or trim(p_customer_name) = '' then
    raise exception 'Customer name is required.';
  end if;
  v_name := trim(p_customer_name);

  select id into v_id from customers where lower(trim(name)) = lower(v_name);
  if v_id is not null then
    return v_id;
  end if;

  v_customer_number := next_id(coalesce(get_settings()->>'customerNumberPrefix', 'CUS-'), 5);
  insert into customers (customer_id, name, active, created_by, last_modified_by)
    values (v_customer_number, v_name, true, v_staff.name, v_staff.name)
  returning id into v_id;
  return v_id;
end;
$$;

grant execute on function resolve_customer(text, text) to authenticated;

-- ---------- PRICE / BOTTLE-ADJUSTMENT LOOKUP ----------
-- Mirrors Code.gs's getEffectivePrice()/getEffectiveBottleAdjustment():
-- most recent entry with effective_from <= the sale date wins. Prices
-- are required (a sale can't be priced without one); bottle
-- adjustments default to 0 when none exists, since most sales aren't
-- "own bottle" sales at all.

create or replace function get_effective_price(p_item_id uuid, p_on_date date) returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_price numeric;
begin
  select price into v_price from price_history
    where item_id = p_item_id and effective_from <= p_on_date
    order by effective_from desc limit 1;
  if v_price is null then
    raise exception 'No price set for this item on or before %.', p_on_date;
  end if;
  return v_price;
end;
$$;

create or replace function get_effective_bottle_adjustment(p_item_id uuid, p_on_date date) returns numeric
language sql
security definer
set search_path = public
as $$
  select coalesce(
    (select amount from bottle_adjustments
      where item_id = p_item_id and effective_from <= p_on_date
      order by effective_from desc limit 1),
    0
  );
$$;

-- ---------- INTERNAL: item lookup by whatever id the frontend sent ----------
-- Items (owned by another domain in this migration) carry both a uuid
-- primary key and a legacy_item_id text column for rows imported from
-- the old Items sheet. Line items from app.js pass back whatever
-- listItems() gave them as `ItemId`, which may be either form
-- depending on how that domain surfaces it — accept both here rather
-- than assuming one.

create or replace function resolve_item(p_item_id text) returns items
language sql
security definer
set search_path = public
as $$
  select * from items where id::text = p_item_id or legacy_item_id = p_item_id limit 1;
$$;

-- ---------- SALES ----------

-- Builds the PascalCase Sales-row jsonb Code.gs's Sheet row shape had.
-- CustomerId is the human-readable text id (not the internal uuid) —
-- app.js compares this against customers' own CustomerId everywhere.
create or replace function sale_to_json(p_sale sales) returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'SaleId', p_sale.sale_id,
    'SaleDate', p_sale.sale_date,
    'CustomerId', (select customer_id from customers where id = p_sale.customer_id),
    'Subtotal', p_sale.subtotal,
    'TaxAmount', p_sale.tax_amount,
    'GrandTotal', p_sale.grand_total,
    'AmountReceived', p_sale.amount_received,
    'Outstanding', p_sale.outstanding,
    'GstEnabled', p_sale.gst_enabled,
    'QuotationRef', coalesce(p_sale.quotation_ref, ''),
    'Status', p_sale.status,
    'VoidReason', coalesce(p_sale.void_reason, ''),
    'CreatedBy', p_sale.created_by,
    'CreatedDate', p_sale.created_at,
    'LastModifiedBy', p_sale.last_modified_by,
    'LastModifiedDate', p_sale.last_modified_at
  );
$$;

create or replace function sale_item_to_json(p_si sale_items) returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'SaleItemId', p_si.sale_item_id,
    'SaleId', p_si.sale_id,
    -- Always the uuid-as-text, not legacy_item_id — matches the
    -- convention the Items/Quotations domains settled on, since
    -- legacy_item_id is null for every item until a Sheets data
    -- import happens (see supabase/staff/README.md).
    'ItemId', (select id::text from items where id = p_si.item_id),
    'Quantity', p_si.quantity,
    'Unit', p_si.unit,
    'BaseRate', p_si.base_rate,
    'BottleAdjustment', p_si.bottle_adjustment,
    'FinalRate', p_si.final_rate,
    'Amount', p_si.amount,
    'TaxRate', p_si.tax_rate,
    'TaxAmount', p_si.tax_amount
  );
$$;

-- Any active staff member may record a sale (matches Code.gs — sales
-- entry is not Admin-gated, unlike voiding one).
create or replace function create_sale(p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_sale_date date;
  v_customer_id uuid;
  v_settings jsonb;
  v_gst_enabled boolean;
  v_sale_id text;
  v_line jsonb;
  v_item items;
  v_quantity numeric;
  v_own_bottle boolean;
  v_base_rate numeric;
  v_bottle_adj numeric;
  v_final_rate numeric;
  v_amount numeric;
  v_tax_rate numeric;
  v_tax_amount numeric;
  v_subtotal numeric := 0;
  v_tax_total numeric := 0;
  v_grand_total numeric;
  v_amount_received numeric;
  v_sale sales;
  v_items_json jsonb := '[]'::jsonb;
  v_si sale_items;
  v_payment_id text;
begin
  v_staff := require_staff();

  if p_payload->'items' is null or jsonb_array_length(p_payload->'items') = 0 then
    raise exception 'At least one line item is required.';
  end if;

  v_sale_date := coalesce((p_payload->>'saleDate')::date, current_date);
  v_customer_id := resolve_customer(p_payload->>'customerId', p_payload->>'customerName');

  v_settings := get_settings();
  v_gst_enabled := (v_settings->>'gstEnabled') = 'true';
  v_sale_id := next_id(coalesce(v_settings->>'saleNumberPrefix', 'SALE-'), 6);

  insert into sales (
    sale_id, sale_date, customer_id, subtotal, tax_amount, grand_total,
    amount_received, outstanding, gst_enabled, quotation_ref, status,
    created_by, last_modified_by
  ) values (
    v_sale_id, v_sale_date, v_customer_id, 0, 0, 0,
    0, 0, v_gst_enabled, nullif(p_payload->>'quotationRef', ''), 'Active',
    v_staff.name, v_staff.name
  );

  for v_line in select * from jsonb_array_elements(p_payload->'items') loop
    v_item := resolve_item(v_line->>'itemId');
    if v_item.id is null then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_quantity := (v_line->>'quantity')::numeric;
    if not (v_quantity > 0) then
      raise exception 'Quantity must be greater than zero for %', v_item.name;
    end if;
    v_own_bottle := coalesce((v_line->>'ownBottle')::boolean, false);
    v_base_rate := get_effective_price(v_item.id, v_sale_date);
    v_bottle_adj := case when v_own_bottle then get_effective_bottle_adjustment(v_item.id, v_sale_date) else 0 end;
    v_final_rate := round(v_base_rate - v_bottle_adj, 2);
    v_amount := round(v_quantity * v_final_rate, 2);
    v_tax_rate := case when v_gst_enabled then coalesce(v_item.tax_rate, 0) else 0 end;
    v_tax_amount := round(v_amount * v_tax_rate / 100, 2);
    v_subtotal := v_subtotal + v_amount;
    v_tax_total := v_tax_total + v_tax_amount;

    insert into sale_items (
      sale_item_id, sale_id, item_id, quantity, unit, base_rate,
      bottle_adjustment, final_rate, amount, tax_rate, tax_amount
    ) values (
      next_id('SI', 6), v_sale_id, v_item.id, v_quantity, v_item.unit, v_base_rate,
      v_bottle_adj, v_final_rate, v_amount, v_tax_rate, v_tax_amount
    ) returning * into v_si;

    perform record_stock_movement(v_item.id, -abs(v_quantity), v_item.unit, 'Sale', 'Sale', v_sale_id, '', v_staff.name);
    v_items_json := v_items_json || jsonb_build_array(sale_item_to_json(v_si));
  end loop;

  v_grand_total := round(v_subtotal + v_tax_total, 2);
  v_amount_received := round(coalesce((p_payload->>'amountReceived')::numeric, 0), 2);

  update sales set
    subtotal = round(v_subtotal, 2),
    tax_amount = round(v_tax_total, 2),
    grand_total = v_grand_total,
    amount_received = v_amount_received,
    outstanding = round(v_grand_total - v_amount_received, 2)
  where sale_id = v_sale_id
  returning * into v_sale;

  if v_amount_received > 0 then
    v_payment_id := next_id(coalesce(v_settings->>'paymentNumberPrefix', 'PAY-'), 6);
    insert into payments (payment_id, customer_id, sale_id, amount, payment_date, method, notes, created_by)
      values (v_payment_id, v_customer_id, v_sale_id, v_amount_received, v_sale_date,
              coalesce(nullif(p_payload->>'paymentMethod', ''), 'Cash'), 'Received at time of sale', v_staff.name);
  end if;

  return jsonb_build_object('sale', sale_to_json(v_sale), 'items', v_items_json);
end;
$$;

-- Edits items/customer/date on an existing, non-voided sale. Reverses
-- the old stock impact and applies the new one; AmountReceived is left
-- untouched (payments are managed separately via record_payment) —
-- same behavior as Code.gs's updateSale().
create or replace function update_sale(p_sale_id text, p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_sale sales;
  v_old_si sale_items;
  v_customer_id uuid;
  v_sale_date date;
  v_settings jsonb;
  v_gst_enabled boolean;
  v_line jsonb;
  v_item items;
  v_quantity numeric;
  v_own_bottle boolean;
  v_base_rate numeric;
  v_bottle_adj numeric;
  v_final_rate numeric;
  v_amount numeric;
  v_tax_rate numeric;
  v_tax_amount numeric;
  v_subtotal numeric := 0;
  v_tax_total numeric := 0;
  v_grand_total numeric;
  v_items_json jsonb := '[]'::jsonb;
  v_si sale_items;
begin
  v_staff := require_staff();

  select * into v_sale from sales where sale_id = p_sale_id;
  if v_sale.id is null then
    raise exception 'Sale not found.';
  end if;
  if v_sale.status = 'Voided' then
    raise exception 'This sale has been voided and cannot be edited.';
  end if;
  if p_payload->'items' is null or jsonb_array_length(p_payload->'items') = 0 then
    raise exception 'At least one line item is required.';
  end if;

  -- Reverse the old line items' stock impact before deleting them.
  for v_old_si in select * from sale_items where sale_id = p_sale_id loop
    perform record_stock_movement(v_old_si.item_id, abs(v_old_si.quantity), v_old_si.unit, 'SaleEdit', 'Sale', p_sale_id, 'Reversed for edit', v_staff.name);
  end loop;
  delete from sale_items where sale_id = p_sale_id;

  v_customer_id := resolve_customer(p_payload->>'customerId', p_payload->>'customerName');
  v_sale_date := coalesce((p_payload->>'saleDate')::date, v_sale.sale_date);
  v_settings := get_settings();
  v_gst_enabled := (v_settings->>'gstEnabled') = 'true';

  for v_line in select * from jsonb_array_elements(p_payload->'items') loop
    v_item := resolve_item(v_line->>'itemId');
    if v_item.id is null then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_quantity := (v_line->>'quantity')::numeric;
    if not (v_quantity > 0) then
      raise exception 'Quantity must be greater than zero for %', v_item.name;
    end if;
    v_own_bottle := coalesce((v_line->>'ownBottle')::boolean, false);
    v_base_rate := get_effective_price(v_item.id, v_sale_date);
    v_bottle_adj := case when v_own_bottle then get_effective_bottle_adjustment(v_item.id, v_sale_date) else 0 end;
    v_final_rate := round(v_base_rate - v_bottle_adj, 2);
    v_amount := round(v_quantity * v_final_rate, 2);
    v_tax_rate := case when v_gst_enabled then coalesce(v_item.tax_rate, 0) else 0 end;
    v_tax_amount := round(v_amount * v_tax_rate / 100, 2);
    v_subtotal := v_subtotal + v_amount;
    v_tax_total := v_tax_total + v_tax_amount;

    insert into sale_items (
      sale_item_id, sale_id, item_id, quantity, unit, base_rate,
      bottle_adjustment, final_rate, amount, tax_rate, tax_amount
    ) values (
      next_id('SI', 6), p_sale_id, v_item.id, v_quantity, v_item.unit, v_base_rate,
      v_bottle_adj, v_final_rate, v_amount, v_tax_rate, v_tax_amount
    ) returning * into v_si;

    perform record_stock_movement(v_item.id, -abs(v_quantity), v_item.unit, 'SaleEdit', 'Sale', p_sale_id, 'Applied after edit', v_staff.name);
    v_items_json := v_items_json || jsonb_build_array(sale_item_to_json(v_si));
  end loop;

  v_grand_total := round(v_subtotal + v_tax_total, 2);

  update sales set
    customer_id = v_customer_id,
    sale_date = v_sale_date,
    subtotal = round(v_subtotal, 2),
    tax_amount = round(v_tax_total, 2),
    grand_total = v_grand_total,
    outstanding = round(v_grand_total - v_sale.amount_received, 2),
    last_modified_by = v_staff.name,
    last_modified_at = now()
  where sale_id = p_sale_id
  returning * into v_sale;

  return jsonb_build_object('sale', sale_to_json(v_sale), 'items', v_items_json);
end;
$$;

-- Void, not delete: reverses stock via an offsetting ledger entry and
-- marks the sale Voided (excluded from revenue totals, hidden from
-- "record a payment against this sale" flows) but keeps the row —
-- deleting it outright would orphan its stock movements and any
-- payment already recorded against it. Admin-only, matching Code.gs.
create or replace function void_sale(p_sale_id text, p_reason text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_sale sales;
  v_si sale_items;
begin
  v_staff := require_admin();

  if p_reason is null or trim(p_reason) = '' then
    raise exception 'A reason is required to void a sale.';
  end if;

  select * into v_sale from sales where sale_id = p_sale_id;
  if v_sale.id is null then
    raise exception 'Sale not found.';
  end if;
  if v_sale.status = 'Voided' then
    raise exception 'This sale is already voided.';
  end if;

  for v_si in select * from sale_items where sale_id = p_sale_id loop
    perform record_stock_movement(v_si.item_id, abs(v_si.quantity), v_si.unit, 'SaleVoid', 'Sale', p_sale_id, 'Sale voided: ' || p_reason, v_staff.name);
  end loop;

  update sales set
    status = 'Voided',
    void_reason = p_reason,
    outstanding = 0,
    last_modified_by = v_staff.name,
    last_modified_at = now()
  where sale_id = p_sale_id
  returning * into v_sale;

  -- Code.gs's voidSale() returned the flat sale row (not wrapped in
  -- {sale: ...}) — app.js doesn't inspect this response at all
  -- (screenSaleDetail just re-fetches getSaleDetail after), but kept
  -- flat here for parity.
  return sale_to_json(v_sale);
end;
$$;

-- One-tap version of record_payment() for a single sale's full
-- outstanding balance — same effect as allocating the whole amount to
-- that one sale.
create or replace function mark_sale_as_paid(p_sale_id text, p_method text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_sale sales;
  v_outstanding numeric;
  v_settings jsonb;
begin
  v_staff := require_staff();

  select * into v_sale from sales where sale_id = p_sale_id;
  if v_sale.id is null then
    raise exception 'Sale not found.';
  end if;
  if v_sale.status = 'Voided' then
    raise exception 'This sale is voided.';
  end if;
  v_outstanding := round(v_sale.grand_total - v_sale.amount_received, 2);
  if v_outstanding <= 0 then
    raise exception 'This sale is already fully paid.';
  end if;

  v_settings := get_settings();
  insert into payments (payment_id, customer_id, sale_id, amount, payment_date, method, notes, created_by)
    values (next_id(coalesce(v_settings->>'paymentNumberPrefix', 'PAY-'), 6), v_sale.customer_id, p_sale_id,
            v_outstanding, current_date, coalesce(nullif(p_method, ''), 'Cash'), 'Marked as paid', v_staff.name);

  update sales set
    amount_received = grand_total,
    outstanding = 0,
    last_modified_by = v_staff.name,
    last_modified_at = now()
  where sale_id = p_sale_id
  returning * into v_sale;

  return sale_to_json(v_sale);
end;
$$;

-- Mirrors Code.gs's enrichSalesWithDetails(): adds camelCase
-- customerName + items[{itemName, quantity, unit}] to each sale row —
-- NOTE these three keys stay lowercase/camelCase (not PascalCase),
-- exactly matching what js/app.js's screenSales() reads
-- (s.customerName, s.items.map(i => i.itemName...)).
create or replace function list_sales(p_filters jsonb default '{}'::jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  perform require_staff();

  select coalesce(jsonb_agg(obj order by sort_date desc, sort_created desc), '[]'::jsonb) into v_result
  from (
    select
      s.sale_date as sort_date,
      s.created_at as sort_created,
      sale_to_json(s) || jsonb_build_object(
        'customerName', c.name,
        'items', coalesce((
          select jsonb_agg(jsonb_build_object('itemName', i.name, 'quantity', si.quantity, 'unit', si.unit))
          from sale_items si join items i on i.id = si.item_id
          where si.sale_id = s.sale_id
        ), '[]'::jsonb)
      ) as obj
    from sales s
    join customers c on c.id = s.customer_id
    where (p_filters->>'customerId' is null or c.customer_id = p_filters->>'customerId')
      and (p_filters->>'fromDate' is null or s.sale_date >= (p_filters->>'fromDate')::date)
      and (p_filters->>'toDate' is null or s.sale_date <= (p_filters->>'toDate')::date)
  ) t;

  return v_result;
end;
$$;

-- Mirrors Code.gs's getSaleDetail(): sale + its line items (each with
-- an added lowercase "itemName" convenience key, same as
-- Object.assign({}, i, {itemName: ...}) there) + the customer row.
create or replace function get_sale_detail(p_sale_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_sale sales;
  v_customer customers;
  v_items jsonb;
begin
  perform require_staff();

  select * into v_sale from sales where sale_id = p_sale_id;
  if v_sale.id is null then
    raise exception 'Sale not found.';
  end if;

  select * into v_customer from customers where id = v_sale.customer_id;

  select coalesce(jsonb_agg(sale_item_to_json(si) || jsonb_build_object('itemName', i.name) order by si.id), '[]'::jsonb)
    into v_items
  from sale_items si join items i on i.id = si.item_id
  where si.sale_id = p_sale_id;

  return jsonb_build_object(
    'sale', sale_to_json(v_sale),
    'items', v_items,
    'customer', case when v_customer.id is null then null else jsonb_build_object(
      'CustomerId', v_customer.customer_id,
      'Name', v_customer.name,
      'Active', v_customer.active,
      'CreatedDate', v_customer.created_at,
      'CreatedBy', v_customer.created_by,
      'LastModifiedDate', v_customer.last_modified_at,
      'LastModifiedBy', v_customer.last_modified_by
    ) end
  );
end;
$$;

-- ---------- PAYMENTS ----------

create or replace function payment_to_json(p_pay payments) returns jsonb
language sql
stable
as $$
  select jsonb_build_object(
    'PaymentId', p_pay.payment_id,
    'CustomerId', (select customer_id from customers where id = p_pay.customer_id),
    'SaleId', coalesce(p_pay.sale_id, ''),
    'Amount', p_pay.amount,
    'PaymentDate', p_pay.payment_date,
    'Method', p_pay.method,
    'Notes', coalesce(p_pay.notes, ''),
    'CreatedBy', p_pay.created_by,
    'CreatedDate', p_pay.created_at
  );
$$;

-- payload: { customerId, amount (total received), paymentDate, method,
-- notes, allocations: [{saleId, amount}] }.
-- Each allocation creates its own Payment row AND updates that Sale's
-- AmountReceived/Outstanding — this is what keeps a sale's own paid
-- status accurate over time instead of only the customer-level ledger.
-- If allocations sum to less than the total amount, the remainder is
-- recorded as one unallocated Payment row (an advance/credit not tied
-- to any specific sale). Allocations summing to more than the total
-- amount is rejected (with a 1-cent rounding tolerance) — fix the
-- split or increase the amount. Mirrors Code.gs's recordPayment().
create or replace function record_payment(p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_customer_text text;
  v_customer_id uuid;
  v_total_amount numeric;
  v_settings jsonb;
  v_payment_date date;
  v_method text;
  v_notes text;
  v_alloc jsonb;
  v_alloc_sale_id text;
  v_alloc_amount numeric;
  v_allocated_total numeric := 0;
  v_remainder numeric;
  v_sale sales;
  v_payment payments;
  v_payments_json jsonb := '[]'::jsonb;
  v_allocations jsonb := '[]'::jsonb;
begin
  v_staff := require_staff();

  v_customer_text := p_payload->>'customerId';
  select id into v_customer_id from customers where customer_id = v_customer_text;
  if v_customer_id is null then
    raise exception 'Customer not found.';
  end if;

  v_total_amount := round(coalesce((p_payload->>'amount')::numeric, 0), 2);
  if not (v_total_amount > 0) then
    raise exception 'Payment amount must be greater than zero.';
  end if;

  v_settings := get_settings();
  v_payment_date := coalesce((p_payload->>'paymentDate')::date, current_date);
  v_method := coalesce(nullif(p_payload->>'method', ''), 'Cash');
  v_notes := coalesce(p_payload->>'notes', '');

  -- Filter to allocations with a saleId and a positive amount, same as
  -- Code.gs's Array#filter step, before summing/validating.
  for v_alloc in select * from jsonb_array_elements(coalesce(p_payload->'allocations', '[]'::jsonb)) loop
    if (v_alloc->>'saleId') is not null and trim(v_alloc->>'saleId') <> '' and coalesce((v_alloc->>'amount')::numeric, 0) > 0 then
      v_allocations := v_allocations || jsonb_build_array(jsonb_build_object('saleId', v_alloc->>'saleId', 'amount', round((v_alloc->>'amount')::numeric, 2)));
      v_allocated_total := v_allocated_total + round((v_alloc->>'amount')::numeric, 2);
    end if;
  end loop;
  v_allocated_total := round(v_allocated_total, 2);

  if v_allocated_total - v_total_amount > 0.01 then
    raise exception 'The amounts applied to sales add up to more than the payment amount.';
  end if;

  for v_alloc in select * from jsonb_array_elements(v_allocations) loop
    v_alloc_sale_id := v_alloc->>'saleId';
    v_alloc_amount := (v_alloc->>'amount')::numeric;

    select * into v_sale from sales where sale_id = v_alloc_sale_id and customer_id = v_customer_id;
    if v_sale.id is null then
      raise exception 'Sale not found for allocation: %', v_alloc_sale_id;
    end if;
    if v_sale.status = 'Voided' then
      raise exception 'Cannot apply a payment to a voided sale: %', v_alloc_sale_id;
    end if;

    insert into payments (payment_id, customer_id, sale_id, amount, payment_date, method, notes, created_by)
      values (next_id(coalesce(v_settings->>'paymentNumberPrefix', 'PAY-'), 6), v_customer_id, v_alloc_sale_id,
              v_alloc_amount, v_payment_date, v_method, v_notes, v_staff.name)
      returning * into v_payment;
    v_payments_json := v_payments_json || jsonb_build_array(payment_to_json(v_payment));

    update sales set
      amount_received = round(amount_received + v_alloc_amount, 2),
      outstanding = round(grand_total - round(amount_received + v_alloc_amount, 2), 2),
      last_modified_by = v_staff.name,
      last_modified_at = now()
    where sale_id = v_alloc_sale_id;
  end loop;

  v_remainder := round(v_total_amount - v_allocated_total, 2);
  if v_remainder > 0.004 then
    insert into payments (payment_id, customer_id, sale_id, amount, payment_date, method, notes, created_by)
      values (next_id(coalesce(v_settings->>'paymentNumberPrefix', 'PAY-'), 6), v_customer_id, null,
              v_remainder, v_payment_date, v_method, coalesce(nullif(v_notes, ''), 'Unallocated / advance'), v_staff.name)
      returning * into v_payment;
    v_payments_json := v_payments_json || jsonb_build_array(payment_to_json(v_payment));
  end if;

  return jsonb_build_object('payments', v_payments_json);
end;
$$;

create or replace function list_payments(p_filters jsonb default '{}'::jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_result jsonb;
begin
  perform require_staff();

  select coalesce(jsonb_agg(payment_to_json(p) order by p.payment_date desc, p.created_at desc), '[]'::jsonb)
    into v_result
  from payments p
  join customers c on c.id = p.customer_id
  where p_filters->>'customerId' is null or c.customer_id = p_filters->>'customerId';

  return v_result;
end;
$$;

-- ---------- GRANTS ----------

grant execute on function get_effective_price(uuid, date) to authenticated;
grant execute on function get_effective_bottle_adjustment(uuid, date) to authenticated;
grant execute on function create_sale(jsonb) to authenticated;
grant execute on function update_sale(text, jsonb) to authenticated;
grant execute on function void_sale(text, text) to authenticated;
grant execute on function mark_sale_as_paid(text, text) to authenticated;
grant execute on function list_sales(jsonb) to authenticated;
grant execute on function get_sale_detail(text) to authenticated;
grant execute on function record_payment(jsonb) to authenticated;
grant execute on function list_payments(jsonb) to authenticated;
