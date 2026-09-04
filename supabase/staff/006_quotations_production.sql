-- ==========================================================================
-- Sri Products — Business Manager migration onto Supabase (Phase 5c):
-- Quotations and Production. Run in the SQL Editor AFTER schema.sql,
-- 002_delivery.sql, 003_online_payment.sql, and staff/004_staff_foundation.sql
-- (which created the quotations/quotation_items/production/
-- production_inputs/production_outputs tables and the require_staff()/
-- require_admin()/next_id()/record_stock_movement()/get_settings()
-- primitives this file builds on).
--
-- This file only owns Quotations and Production — Sales/Payments/
-- Customers-proper and Items/Prices/Stock-adjustments are ported by
-- sibling files in this same folder, run independently. Every function
-- here is self-contained (including its own copy of resolve_customer,
-- and its own minimal Sales/Payments inserts for convertQuotationToSale)
-- so this file has no load-order dependency on those siblings.
--
-- Casing note: Quotations mirror Code.gs's Sheets-column casing
-- (QuotationId, CustomerId, GrandTotal, ...) plus an added lowercase
-- `itemName` on line items, same convention Sales uses. Production
-- mirrors Code.gs's listProduction()/getProductionDetail() shape
-- exactly, which is already camelCase (productionId, date, notes,
-- inputs: [{itemId, itemName, quantity}], outputs: [...]) — do not mix
-- the two casings up between domains.
-- ==========================================================================

-- ---------- CUSTOMERS: resolve_customer ----------
-- Same customer-name-or-id resolution logic Sales uses (Code.gs's
-- resolveCustomer/createCustomer). Defined here too, per the migration
-- plan, since `create or replace function` makes whichever copy runs
-- last win — harmless, since the logic is identical either way.
-- Match-by-name is exact (trimmed, case-insensitive) only, on purpose —
-- no fuzzy matching, to avoid silently merging two different customers.
--
-- IMPORTANT: p_customer_id is the human-readable text customer_id
-- (e.g. 'CUS-00012'), NOT the internal uuid — this must match the
-- Sales domain's resolve_customer(text, text) signature exactly, or
-- Postgres treats them as two different overloaded functions instead
-- of one replacing the other. app.js never actually has the internal
-- uuid to send in the first place (only the human-readable id or a
-- typed name), so `text` is the only signature that makes sense here.

create or replace function resolve_customer(p_customer_id text, p_customer_name text) returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_id uuid;
  v_name text;
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

  insert into customers (customer_id, name, active, created_by, last_modified_by)
  values (next_id(coalesce(get_settings()->>'customerNumberPrefix', 'CUS-'), 5), v_name, true, v_staff.name, v_staff.name)
  returning id into v_id;
  return v_id;
end;
$$;

-- ==========================================================================
-- ---------- QUOTATIONS ----------
-- ==========================================================================

create or replace function create_quotation(p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_quote_date date;
  v_customer_id uuid;
  v_customer_code text;
  v_settings jsonb;
  v_gst_enabled boolean;
  v_quotation_id text;
  v_subtotal numeric := 0;
  v_tax_total numeric := 0;
  v_line jsonb;
  v_item_id uuid;
  v_i_name text;
  v_i_unit text;
  v_i_tax numeric;
  v_qty numeric;
  v_base_rate numeric;
  v_bottle_adj numeric;
  v_final_rate numeric;
  v_amount numeric;
  v_tax_rate numeric;
  v_tax_amount numeric;
  v_valid_until date;
  v_items_json jsonb;
  v_quotation_json jsonb;
begin
  v_staff := require_staff();

  if p_payload->'items' is null or jsonb_array_length(p_payload->'items') = 0 then
    raise exception 'At least one line item is required.';
  end if;

  v_quote_date := coalesce((p_payload->>'quotationDate')::date, current_date);
  v_customer_id := resolve_customer(nullif(p_payload->>'customerId', ''), p_payload->>'customerName');
  select customer_id into v_customer_code from customers where id = v_customer_id;

  v_settings := get_settings();
  v_gst_enabled := (v_settings->>'gstEnabled') = 'true';
  v_quotation_id := next_id(coalesce(v_settings->>'quotationNumberPrefix', 'QT-'), 6);
  v_valid_until := nullif(p_payload->>'validUntil', '')::date;

  for v_line in select * from jsonb_array_elements(p_payload->'items') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select name, unit, tax_rate into v_i_name, v_i_unit, v_i_tax from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;

    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantity must be greater than zero for %', v_i_name;
    end if;

    select price into v_base_rate from price_history
      where item_id = v_item_id and effective_from <= v_quote_date
      order by effective_from desc limit 1;
    if v_base_rate is null then
      raise exception 'No price set for this item on or before %.', v_quote_date;
    end if;

    v_bottle_adj := 0;
    if coalesce((v_line->>'ownBottle')::boolean, false) then
      select amount into v_bottle_adj from bottle_adjustments
        where item_id = v_item_id and effective_from <= v_quote_date
        order by effective_from desc limit 1;
      v_bottle_adj := coalesce(v_bottle_adj, 0);
    end if;

    v_final_rate := round((v_base_rate - v_bottle_adj)::numeric, 2);
    v_amount := round((v_qty * v_final_rate)::numeric, 2);
    v_tax_rate := case when v_gst_enabled then coalesce(v_i_tax, 0) else 0 end;
    v_tax_amount := round((v_amount * v_tax_rate / 100)::numeric, 2);
    v_subtotal := v_subtotal + v_amount;
    v_tax_total := v_tax_total + v_tax_amount;

    insert into quotation_items (quotation_item_id, quotation_id, item_id, quantity, unit, base_rate, bottle_adjustment, final_rate, amount, tax_rate, tax_amount)
    values (next_id('QI', 6), v_quotation_id, v_item_id, v_qty, v_i_unit, v_base_rate, v_bottle_adj, v_final_rate, v_amount, v_tax_rate, v_tax_amount);
  end loop;

  insert into quotations (quotation_id, quotation_date, customer_id, subtotal, tax_amount, grand_total, valid_until, status, created_by, last_modified_by)
  values (v_quotation_id, v_quote_date, v_customer_id, round(v_subtotal, 2), round(v_tax_total, 2), round(v_subtotal + v_tax_total, 2), v_valid_until, 'Draft', v_staff.name, v_staff.name);

  select coalesce(jsonb_agg(jsonb_build_object(
      'QuotationItemId', qi.quotation_item_id, 'QuotationId', qi.quotation_id, 'ItemId', qi.item_id::text,
      'itemName', i.name, 'Quantity', qi.quantity, 'Unit', qi.unit, 'BaseRate', qi.base_rate,
      'BottleAdjustment', qi.bottle_adjustment, 'FinalRate', qi.final_rate, 'Amount', qi.amount,
      'TaxRate', qi.tax_rate, 'TaxAmount', qi.tax_amount
    ) order by qi.quotation_item_id), '[]'::jsonb)
    into v_items_json
    from quotation_items qi join items i on i.id = qi.item_id
    where qi.quotation_id = v_quotation_id;

  select jsonb_build_object(
      'QuotationId', q.quotation_id, 'QuotationDate', q.quotation_date, 'CustomerId', v_customer_code,
      'Subtotal', q.subtotal, 'TaxAmount', q.tax_amount, 'GrandTotal', q.grand_total, 'ValidUntil', q.valid_until,
      'Status', q.status, 'CreatedBy', q.created_by, 'CreatedDate', q.created_at,
      'LastModifiedBy', q.last_modified_by, 'LastModifiedDate', q.last_modified_at
    ) into v_quotation_json
    from quotations q where q.quotation_id = v_quotation_id;

  return jsonb_build_object('quotation', v_quotation_json, 'items', v_items_json);
end;
$$;

create or replace function update_quotation(p_quotation_id text, p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_existing quotations%rowtype;
  v_quote_date date;
  v_customer_id uuid;
  v_customer_code text;
  v_settings jsonb;
  v_gst_enabled boolean;
  v_subtotal numeric := 0;
  v_tax_total numeric := 0;
  v_line jsonb;
  v_item_id uuid;
  v_i_name text;
  v_i_unit text;
  v_i_tax numeric;
  v_qty numeric;
  v_base_rate numeric;
  v_bottle_adj numeric;
  v_final_rate numeric;
  v_amount numeric;
  v_tax_rate numeric;
  v_tax_amount numeric;
  v_items_json jsonb;
  v_quotation_json jsonb;
begin
  v_staff := require_staff();

  select * into v_existing from quotations where quotation_id = p_quotation_id;
  if not found then
    raise exception 'Quotation not found.';
  end if;
  if v_existing.status = 'Converted' then
    raise exception 'This quotation has been converted to a sale and cannot be edited.';
  end if;
  if p_payload->'items' is null or jsonb_array_length(p_payload->'items') = 0 then
    raise exception 'At least one line item is required.';
  end if;

  delete from quotation_items where quotation_id = p_quotation_id;

  v_customer_id := resolve_customer(nullif(p_payload->>'customerId', ''), p_payload->>'customerName');
  select customer_id into v_customer_code from customers where id = v_customer_id;
  v_quote_date := coalesce((p_payload->>'quotationDate')::date, v_existing.quotation_date);

  v_settings := get_settings();
  v_gst_enabled := (v_settings->>'gstEnabled') = 'true';

  for v_line in select * from jsonb_array_elements(p_payload->'items') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select name, unit, tax_rate into v_i_name, v_i_unit, v_i_tax from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;

    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Quantity must be greater than zero for %', v_i_name;
    end if;

    select price into v_base_rate from price_history
      where item_id = v_item_id and effective_from <= v_quote_date
      order by effective_from desc limit 1;
    if v_base_rate is null then
      raise exception 'No price set for this item on or before %.', v_quote_date;
    end if;

    v_bottle_adj := 0;
    if coalesce((v_line->>'ownBottle')::boolean, false) then
      select amount into v_bottle_adj from bottle_adjustments
        where item_id = v_item_id and effective_from <= v_quote_date
        order by effective_from desc limit 1;
      v_bottle_adj := coalesce(v_bottle_adj, 0);
    end if;

    v_final_rate := round((v_base_rate - v_bottle_adj)::numeric, 2);
    v_amount := round((v_qty * v_final_rate)::numeric, 2);
    v_tax_rate := case when v_gst_enabled then coalesce(v_i_tax, 0) else 0 end;
    v_tax_amount := round((v_amount * v_tax_rate / 100)::numeric, 2);
    v_subtotal := v_subtotal + v_amount;
    v_tax_total := v_tax_total + v_tax_amount;

    insert into quotation_items (quotation_item_id, quotation_id, item_id, quantity, unit, base_rate, bottle_adjustment, final_rate, amount, tax_rate, tax_amount)
    values (next_id('QI', 6), p_quotation_id, v_item_id, v_qty, v_i_unit, v_base_rate, v_bottle_adj, v_final_rate, v_amount, v_tax_rate, v_tax_amount);
  end loop;

  -- Mirrors Code.gs exactly: ValidUntil is only overwritten when the
  -- payload actually supplies one — an empty/absent validUntil on edit
  -- leaves the existing value untouched rather than clearing it.
  update quotations set
    customer_id = v_customer_id,
    quotation_date = v_quote_date,
    subtotal = round(v_subtotal, 2),
    tax_amount = round(v_tax_total, 2),
    grand_total = round(v_subtotal + v_tax_total, 2),
    valid_until = coalesce(nullif(p_payload->>'validUntil', '')::date, valid_until),
    last_modified_by = v_staff.name,
    last_modified_at = now()
  where quotation_id = p_quotation_id;

  select coalesce(jsonb_agg(jsonb_build_object(
      'QuotationItemId', qi.quotation_item_id, 'QuotationId', qi.quotation_id, 'ItemId', qi.item_id::text,
      'itemName', i.name, 'Quantity', qi.quantity, 'Unit', qi.unit, 'BaseRate', qi.base_rate,
      'BottleAdjustment', qi.bottle_adjustment, 'FinalRate', qi.final_rate, 'Amount', qi.amount,
      'TaxRate', qi.tax_rate, 'TaxAmount', qi.tax_amount
    ) order by qi.quotation_item_id), '[]'::jsonb)
    into v_items_json
    from quotation_items qi join items i on i.id = qi.item_id
    where qi.quotation_id = p_quotation_id;

  select jsonb_build_object(
      'QuotationId', q.quotation_id, 'QuotationDate', q.quotation_date, 'CustomerId', v_customer_code,
      'Subtotal', q.subtotal, 'TaxAmount', q.tax_amount, 'GrandTotal', q.grand_total, 'ValidUntil', q.valid_until,
      'Status', q.status, 'CreatedBy', q.created_by, 'CreatedDate', q.created_at,
      'LastModifiedBy', q.last_modified_by, 'LastModifiedDate', q.last_modified_at
    ) into v_quotation_json
    from quotations q where q.quotation_id = p_quotation_id;

  return jsonb_build_object('quotation', v_quotation_json, 'items', v_items_json);
end;
$$;

-- Quotations have no downstream stock/payment references (unlike Sales,
-- which Code.gs never hard-deletes), so a real delete is safe and
-- matches deleteQuotation() exactly — no reversing ledger entries needed
-- because quotations never touch inventory in the first place.
create or replace function delete_quotation(p_quotation_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_status text;
begin
  v_staff := require_staff();

  select status into v_status from quotations where quotation_id = p_quotation_id;
  if v_status is null then
    raise exception 'Quotation not found.';
  end if;
  if v_status = 'Converted' then
    raise exception 'This quotation has been converted to a sale and cannot be deleted.';
  end if;

  delete from quotation_items where quotation_id = p_quotation_id;
  delete from quotations where quotation_id = p_quotation_id;
  return jsonb_build_object('deleted', true);
end;
$$;

-- Note: filters.status matches against the *stored* Status column
-- (same as Code.gs's listQuotations, which filters before mapping
-- effectiveQuotationStatus) — only the returned Status value reflects
-- the Draft/Sent-past-ValidUntil -> "Expired" display-only override,
-- the stored row is never mutated by this function.
create or replace function list_quotations(p_filters jsonb default '{}'::jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
begin
  v_staff := require_staff();

  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'QuotationId', q.quotation_id,
      'QuotationDate', q.quotation_date,
      'CustomerId', c.customer_id,
      'Subtotal', q.subtotal,
      'TaxAmount', q.tax_amount,
      'GrandTotal', q.grand_total,
      'ValidUntil', q.valid_until,
      'Status', case
        when q.status in ('Draft', 'Sent') and q.valid_until is not null and q.valid_until::timestamptz < now()
        then 'Expired' else q.status end,
      'CreatedBy', q.created_by,
      'CreatedDate', q.created_at,
      'LastModifiedBy', q.last_modified_by,
      'LastModifiedDate', q.last_modified_at
    ) order by q.quotation_date desc, q.created_at desc)
    from quotations q
    join customers c on c.id = q.customer_id
    where (p_filters->>'customerId' is null or c.customer_id = p_filters->>'customerId')
      and (p_filters->>'status' is null or q.status = p_filters->>'status')
  ), '[]'::jsonb);
end;
$$;

create or replace function get_quotation_detail(p_quotation_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_q quotations%rowtype;
  v_customer customers%rowtype;
  v_status text;
  v_items jsonb;
begin
  v_staff := require_staff();

  select * into v_q from quotations where quotation_id = p_quotation_id;
  if not found then
    raise exception 'Quotation not found.';
  end if;

  select * into v_customer from customers where id = v_q.customer_id;

  v_status := case
    when v_q.status in ('Draft', 'Sent') and v_q.valid_until is not null and v_q.valid_until::timestamptz < now()
    then 'Expired' else v_q.status end;

  select coalesce(jsonb_agg(jsonb_build_object(
      'QuotationItemId', qi.quotation_item_id, 'QuotationId', qi.quotation_id, 'ItemId', qi.item_id::text,
      'itemName', i.name, 'Quantity', qi.quantity, 'Unit', qi.unit, 'BaseRate', qi.base_rate,
      'BottleAdjustment', qi.bottle_adjustment, 'FinalRate', qi.final_rate, 'Amount', qi.amount,
      'TaxRate', qi.tax_rate, 'TaxAmount', qi.tax_amount
    ) order by qi.quotation_item_id), '[]'::jsonb)
    into v_items
    from quotation_items qi join items i on i.id = qi.item_id
    where qi.quotation_id = p_quotation_id;

  return jsonb_build_object(
    'quotation', jsonb_build_object(
      'QuotationId', v_q.quotation_id,
      'QuotationDate', v_q.quotation_date,
      'CustomerId', coalesce(v_customer.customer_id, v_q.customer_id::text),
      'Subtotal', v_q.subtotal,
      'TaxAmount', v_q.tax_amount,
      'GrandTotal', v_q.grand_total,
      'ValidUntil', v_q.valid_until,
      'Status', v_status,
      'CreatedBy', v_q.created_by,
      'CreatedDate', v_q.created_at,
      'LastModifiedBy', v_q.last_modified_by,
      'LastModifiedDate', v_q.last_modified_at
    ),
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

create or replace function update_quotation_status(p_quotation_id text, p_status text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_q quotations%rowtype;
  v_customer_code text;
begin
  v_staff := require_staff();

  update quotations set status = p_status, last_modified_by = v_staff.name, last_modified_at = now()
    where quotation_id = p_quotation_id
    returning * into v_q;
  if not found then
    raise exception 'Quotation not found.';
  end if;

  select customer_id into v_customer_code from customers where id = v_q.customer_id;

  return jsonb_build_object(
    'QuotationId', v_q.quotation_id, 'QuotationDate', v_q.quotation_date, 'CustomerId', v_customer_code,
    'Subtotal', v_q.subtotal, 'TaxAmount', v_q.tax_amount, 'GrandTotal', v_q.grand_total,
    'ValidUntil', v_q.valid_until, 'Status', v_q.status, 'CreatedBy', v_q.created_by, 'CreatedDate', v_q.created_at,
    'LastModifiedBy', v_q.last_modified_by, 'LastModifiedDate', v_q.last_modified_at
  );
end;
$$;

-- Duplicates the minimal Sales/Payments insert logic here (rather than
-- calling another domain's create_sale()) so this file has no load-order
-- dependency on the sibling Sales migration — both files converge on the
-- same `sales`/`sale_items`/`payments` tables defined once in
-- 004_staff_foundation.sql. Rates/amounts are copied verbatim from the
-- quotation's line items, never recomputed against today's price book —
-- a quotation is a promised price, and converting it shouldn't silently
-- reprice the sale.
create or replace function convert_quotation_to_sale(p_quotation_id text, p_payment_amount numeric, p_payment_method text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_detail jsonb;
  v_quotation jsonb;
  v_items jsonb;
  v_status text;
  v_line jsonb;
  v_item_id uuid;
  v_qty numeric;
  v_unit text;
  v_available numeric;
  v_warnings text[] := '{}';
  v_sale_id text;
  v_amount_received numeric;
  v_customer_uuid uuid;
  v_customer_code text;
  v_subtotal numeric;
  v_tax_amount numeric;
  v_grand_total numeric;
  v_sale jsonb;
begin
  v_staff := require_staff();

  v_detail := get_quotation_detail(p_quotation_id);
  v_quotation := v_detail->'quotation';
  v_items := v_detail->'items';
  v_status := v_quotation->>'Status';

  if v_status = 'Converted' then
    raise exception 'This quotation has already been converted to a sale.';
  end if;
  if v_status = 'Expired' then
    raise exception 'This quotation has expired and cannot be converted. Create a new quotation instead.';
  end if;

  -- Stock is checked and reported via stockWarnings but NEVER blocks the
  -- conversion — mirrors Code.gs's convertQuotationToSale() exactly. A
  -- quotation may have been written when stock was sufficient and only
  -- run short by the time it's accepted; staff see the shortfall and
  -- decide manually (partial fulfilment, reorder, etc.) rather than the
  -- system refusing the whole conversion outright.
  for v_line in select * from jsonb_array_elements(v_items) loop
    v_item_id := (v_line->>'ItemId')::uuid;
    v_qty := (v_line->>'Quantity')::numeric;
    select balance into v_available from stock_balances where item_id = v_item_id;
    v_available := coalesce(v_available, 0);
    if v_available < v_qty then
      v_warnings := v_warnings || (
        (v_line->>'itemName') || ': requested ' || v_qty || ' ' || (v_line->>'Unit') ||
        ', only ' || v_available || ' ' || (v_line->>'Unit') || ' in stock.'
      );
    end if;
  end loop;

  v_sale_id := next_id(coalesce(get_settings()->>'saleNumberPrefix', 'SALE-'), 6);
  v_amount_received := round(coalesce(p_payment_amount, 0), 2);
  v_customer_code := v_quotation->>'CustomerId';
  select id into v_customer_uuid from customers where customer_id = v_customer_code;
  v_subtotal := (v_quotation->>'Subtotal')::numeric;
  v_tax_amount := (v_quotation->>'TaxAmount')::numeric;
  v_grand_total := (v_quotation->>'GrandTotal')::numeric;

  insert into sales (sale_id, sale_date, customer_id, subtotal, tax_amount, grand_total, amount_received, outstanding, gst_enabled, quotation_ref, status, created_by, last_modified_by)
  values (v_sale_id, current_date, v_customer_uuid, v_subtotal, v_tax_amount, v_grand_total, v_amount_received, round(v_grand_total - v_amount_received, 2), v_tax_amount > 0, p_quotation_id, 'Active', v_staff.name, v_staff.name);

  for v_line in select * from jsonb_array_elements(v_items) loop
    v_item_id := (v_line->>'ItemId')::uuid;
    v_qty := (v_line->>'Quantity')::numeric;
    v_unit := v_line->>'Unit';

    insert into sale_items (sale_item_id, sale_id, item_id, quantity, unit, base_rate, bottle_adjustment, final_rate, amount, tax_rate, tax_amount)
    values (next_id('SI', 6), v_sale_id, v_item_id, v_qty, v_unit, (v_line->>'BaseRate')::numeric, (v_line->>'BottleAdjustment')::numeric, (v_line->>'FinalRate')::numeric, (v_line->>'Amount')::numeric, (v_line->>'TaxRate')::numeric, (v_line->>'TaxAmount')::numeric);

    perform record_stock_movement(v_item_id, -abs(v_qty), v_unit, 'Sale', 'Sale', v_sale_id, 'Converted from ' || p_quotation_id, v_staff.name);
  end loop;

  if v_amount_received > 0 then
    insert into payments (payment_id, customer_id, sale_id, amount, payment_date, method, notes, created_by)
    values (next_id(coalesce(get_settings()->>'paymentNumberPrefix', 'PAY-'), 6), v_customer_uuid, v_sale_id, v_amount_received, current_date, coalesce(p_payment_method, 'Cash'), 'Received on quotation conversion', v_staff.name);
  end if;

  perform update_quotation_status(p_quotation_id, 'Converted');

  select jsonb_build_object(
    'SaleId', s.sale_id, 'SaleDate', s.sale_date, 'CustomerId', v_customer_code,
    'Subtotal', s.subtotal, 'TaxAmount', s.tax_amount, 'GrandTotal', s.grand_total,
    'AmountReceived', s.amount_received, 'Outstanding', s.outstanding, 'GstEnabled', s.gst_enabled,
    'QuotationRef', s.quotation_ref, 'Status', s.status, 'VoidReason', s.void_reason,
    'CreatedBy', s.created_by, 'CreatedDate', s.created_at, 'LastModifiedBy', s.last_modified_by, 'LastModifiedDate', s.last_modified_at
  ) into v_sale
  from sales s where s.sale_id = v_sale_id;

  return jsonb_build_object('sale', v_sale, 'stockWarnings', to_jsonb(v_warnings));
end;
$$;

-- ==========================================================================
-- ---------- PRODUCTION ----------
-- ==========================================================================

create or replace function create_production(p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_production_id text;
  v_date date;
  v_line jsonb;
  v_item_id uuid;
  v_unit text;
  v_qty numeric;
begin
  v_staff := require_staff();

  if p_payload->'inputs' is null or jsonb_array_length(p_payload->'inputs') = 0 then
    raise exception 'At least one raw material input is required.';
  end if;
  if p_payload->'outputs' is null or jsonb_array_length(p_payload->'outputs') = 0 then
    raise exception 'At least one output is required.';
  end if;

  v_production_id := next_id('PRD', 6);
  v_date := coalesce((p_payload->>'date')::date, current_date);

  insert into production (production_id, occurred_on, notes, created_by, last_modified_by)
  values (v_production_id, v_date, coalesce(p_payload->>'notes', ''), v_staff.name, v_staff.name);

  for v_line in select * from jsonb_array_elements(p_payload->'inputs') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select unit into v_unit from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Input quantity must be greater than zero.';
    end if;

    insert into production_inputs (production_input_id, production_id, item_id, quantity_consumed)
    values (next_id('PI', 6), v_production_id, v_item_id, v_qty);
    perform record_stock_movement(v_item_id, -v_qty, v_unit, 'Production', 'Production', v_production_id, 'Consumed', v_staff.name);
  end loop;

  for v_line in select * from jsonb_array_elements(p_payload->'outputs') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select unit into v_unit from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Output quantity must be greater than zero.';
    end if;

    insert into production_outputs (production_output_id, production_id, item_id, quantity_produced)
    values (next_id('PO', 6), v_production_id, v_item_id, v_qty);
    perform record_stock_movement(v_item_id, v_qty, v_unit, 'Production', 'Production', v_production_id, 'Produced', v_staff.name);
  end loop;

  -- Code.gs's createProduction() returns only { productionId: ... }, not
  -- the full record — app.js only ever reads res.productionId off this
  -- response (to navigate to the detail screen), so the shape is kept
  -- exactly that narrow here too.
  return jsonb_build_object('productionId', v_production_id);
end;
$$;

-- Reverse-then-recreate: every edit reverses the old inputs/outputs with
-- offsetting ledger entries (never mutating stock_movements history),
-- then applies the new lines as fresh entries — same pattern Code.gs
-- uses, so the ledger always shows what actually happened rather than
-- silently overwriting old quantities in place. Left open to any active
-- staff member (not admin-only) — matches Code.gs, which never calls
-- requireAdmin() inside updateProduction().
create or replace function update_production(p_production_id text, p_payload jsonb) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_exists boolean;
  v_rec record;
  v_line jsonb;
  v_item_id uuid;
  v_unit text;
  v_qty numeric;
begin
  v_staff := require_staff();

  select true into v_exists from production where production_id = p_production_id;
  if v_exists is null then
    raise exception 'Production entry not found.';
  end if;
  if p_payload->'inputs' is null or jsonb_array_length(p_payload->'inputs') = 0 then
    raise exception 'At least one raw material input is required.';
  end if;
  if p_payload->'outputs' is null or jsonb_array_length(p_payload->'outputs') = 0 then
    raise exception 'At least one output is required.';
  end if;

  for v_rec in
    select pi.item_id, pi.quantity_consumed, i.unit
    from production_inputs pi join items i on i.id = pi.item_id
    where pi.production_id = p_production_id
  loop
    perform record_stock_movement(v_rec.item_id, v_rec.quantity_consumed, v_rec.unit, 'ProductionEdit', 'Production', p_production_id, 'Reversed for edit', v_staff.name);
  end loop;

  for v_rec in
    select po.item_id, po.quantity_produced, i.unit
    from production_outputs po join items i on i.id = po.item_id
    where po.production_id = p_production_id
  loop
    perform record_stock_movement(v_rec.item_id, -v_rec.quantity_produced, v_rec.unit, 'ProductionEdit', 'Production', p_production_id, 'Reversed for edit', v_staff.name);
  end loop;

  delete from production_inputs where production_id = p_production_id;
  delete from production_outputs where production_id = p_production_id;

  for v_line in select * from jsonb_array_elements(p_payload->'inputs') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select unit into v_unit from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Input quantity must be greater than zero.';
    end if;

    insert into production_inputs (production_input_id, production_id, item_id, quantity_consumed)
    values (next_id('PI', 6), p_production_id, v_item_id, v_qty);
    perform record_stock_movement(v_item_id, -v_qty, v_unit, 'ProductionEdit', 'Production', p_production_id, 'Applied after edit', v_staff.name);
  end loop;

  for v_line in select * from jsonb_array_elements(p_payload->'outputs') loop
    v_item_id := (v_line->>'itemId')::uuid;
    select unit into v_unit from items where id = v_item_id;
    if not found then
      raise exception 'Item not found: %', (v_line->>'itemId');
    end if;
    v_qty := (v_line->>'quantity')::numeric;
    if v_qty is null or v_qty <= 0 then
      raise exception 'Output quantity must be greater than zero.';
    end if;

    insert into production_outputs (production_output_id, production_id, item_id, quantity_produced)
    values (next_id('PO', 6), p_production_id, v_item_id, v_qty);
    perform record_stock_movement(v_item_id, v_qty, v_unit, 'ProductionEdit', 'Production', p_production_id, 'Applied after edit', v_staff.name);
  end loop;

  update production set
    occurred_on = coalesce((p_payload->>'date')::date, occurred_on),
    notes = coalesce(p_payload->>'notes', ''),
    last_modified_by = v_staff.name,
    last_modified_at = now()
  where production_id = p_production_id;

  return jsonb_build_object('productionId', p_production_id);
end;
$$;

-- Admin-only, unlike update_production above — Code.gs's
-- deleteProduction() calls requireAdmin() while updateProduction() does
-- not, and that asymmetry is preserved exactly. Reverses stock via
-- offsetting entries (the ledger is append-only, never edited/removed)
-- then removes the production record itself — Production has no
-- downstream references the way a Sale's QuotationRef does, so a real
-- delete of the production/production_inputs/production_outputs rows
-- is safe here.
create or replace function delete_production(p_production_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_exists boolean;
  v_rec record;
begin
  v_staff := require_admin();

  select true into v_exists from production where production_id = p_production_id;
  if v_exists is null then
    raise exception 'Production entry not found.';
  end if;

  for v_rec in
    select pi.item_id, pi.quantity_consumed, i.unit
    from production_inputs pi join items i on i.id = pi.item_id
    where pi.production_id = p_production_id
  loop
    perform record_stock_movement(v_rec.item_id, v_rec.quantity_consumed, v_rec.unit, 'ProductionDelete', 'Production', p_production_id, 'Production entry deleted', v_staff.name);
  end loop;

  for v_rec in
    select po.item_id, po.quantity_produced, i.unit
    from production_outputs po join items i on i.id = po.item_id
    where po.production_id = p_production_id
  loop
    perform record_stock_movement(v_rec.item_id, -v_rec.quantity_produced, v_rec.unit, 'ProductionDelete', 'Production', p_production_id, 'Production entry deleted', v_staff.name);
  end loop;

  delete from production_inputs where production_id = p_production_id;
  delete from production_outputs where production_id = p_production_id;
  delete from production where production_id = p_production_id;

  return jsonb_build_object('deleted', true);
end;
$$;

create or replace function list_production() returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_result jsonb;
begin
  v_staff := require_staff();

  select coalesce(jsonb_agg(jsonb_build_object(
      'productionId', p.production_id,
      'date', p.occurred_on,
      'notes', p.notes,
      'inputs', coalesce((
        select jsonb_agg(jsonb_build_object('itemId', pi.item_id::text, 'itemName', i.name, 'quantity', pi.quantity_consumed))
        from production_inputs pi join items i on i.id = pi.item_id
        where pi.production_id = p.production_id
      ), '[]'::jsonb),
      'outputs', coalesce((
        select jsonb_agg(jsonb_build_object('itemId', po.item_id::text, 'itemName', i.name, 'quantity', po.quantity_produced))
        from production_outputs po join items i on i.id = po.item_id
        where po.production_id = p.production_id
      ), '[]'::jsonb)
    ) order by p.occurred_on desc, p.created_at desc), '[]'::jsonb)
  into v_result
  from production p;

  return v_result;
end;
$$;

create or replace function get_production_detail(p_production_id text) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_staff staff_profiles;
  v_result jsonb;
begin
  v_staff := require_staff();

  select jsonb_build_object(
      'productionId', p.production_id,
      'date', p.occurred_on,
      'notes', p.notes,
      'inputs', coalesce((
        select jsonb_agg(jsonb_build_object('itemId', pi.item_id::text, 'itemName', i.name, 'quantity', pi.quantity_consumed))
        from production_inputs pi join items i on i.id = pi.item_id
        where pi.production_id = p.production_id
      ), '[]'::jsonb),
      'outputs', coalesce((
        select jsonb_agg(jsonb_build_object('itemId', po.item_id::text, 'itemName', i.name, 'quantity', po.quantity_produced))
        from production_outputs po join items i on i.id = po.item_id
        where po.production_id = p.production_id
      ), '[]'::jsonb)
    )
  into v_result
  from production p
  where p.production_id = p_production_id;

  if v_result is null then
    raise exception 'Production entry not found.';
  end if;

  return v_result;
end;
$$;

-- ---------- GRANTS ----------
-- Table access itself is never granted to `authenticated` (see
-- 004_staff_foundation.sql note 2) — only these SECURITY DEFINER entry
-- points, each of which calls require_staff()/require_admin() itself.

grant execute on function resolve_customer(text, text) to authenticated;

grant execute on function create_quotation(jsonb) to authenticated;
grant execute on function update_quotation(text, jsonb) to authenticated;
grant execute on function delete_quotation(text) to authenticated;
grant execute on function list_quotations(jsonb) to authenticated;
grant execute on function get_quotation_detail(text) to authenticated;
grant execute on function update_quotation_status(text, text) to authenticated;
grant execute on function convert_quotation_to_sale(text, numeric, text) to authenticated;

grant execute on function create_production(jsonb) to authenticated;
grant execute on function update_production(text, jsonb) to authenticated;
grant execute on function delete_production(text) to authenticated;
grant execute on function list_production() to authenticated;
grant execute on function get_production_detail(text) to authenticated;
