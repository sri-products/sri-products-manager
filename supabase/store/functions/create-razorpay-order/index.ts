// Starts (or resumes) an online payment for an order that was already
// created via the create_order RPC with p_pay_online = true.
//
// Holds RAZORPAY_KEY_SECRET and the Supabase service_role key — both
// set as function secrets (`supabase secrets set ...`), never present
// in any frontend file. The amount charged always comes from the
// order row already stored in the database, never from whatever the
// browser sends, so a tampered client request can't change the price.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.112.4';
import { corsHeaders, jsonResponse, handleOptions } from '../_shared/cors.ts';

const RAZORPAY_KEY_ID = Deno.env.get('RAZORPAY_KEY_ID')!;
const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

Deno.serve(async (req: Request) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed' }, 405);

  try {
    const { order_number } = await req.json();
    if (!order_number) return jsonResponse({ error: 'order_number is required.' }, 400);

    const { data: order, error } = await supabase
      .from('orders')
      .select('id, order_number, grand_total, payment_method, payment_status, status, razorpay_order_id')
      .eq('order_number', order_number)
      .single();

    if (error || !order) return jsonResponse({ error: 'Order not found.' }, 404);
    if (order.payment_method !== 'online') return jsonResponse({ error: 'This order was not set up for online payment.' }, 400);
    if (order.payment_status === 'paid') return jsonResponse({ error: 'This order is already paid.' }, 400);
    if (order.status === 'cancelled') return jsonResponse({ error: 'This order was cancelled.' }, 400);

    // Retrying after closing/dismissing Checkout: reuse the same
    // Razorpay order instead of creating a new one each time.
    if (order.razorpay_order_id) {
      return jsonResponse({
        razorpay_order_id: order.razorpay_order_id,
        amount: Math.round(Number(order.grand_total) * 100),
        currency: 'INR',
        key_id: RAZORPAY_KEY_ID
      });
    }

    const amountPaise = Math.round(Number(order.grand_total) * 100);
    const rzpRes = await fetch('https://api.razorpay.com/v1/orders', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Basic ' + btoa(`${RAZORPAY_KEY_ID}:${RAZORPAY_KEY_SECRET}`)
      },
      body: JSON.stringify({ amount: amountPaise, currency: 'INR', receipt: order.order_number })
    });
    const rzpData = await rzpRes.json();
    if (!rzpRes.ok) {
      return jsonResponse({ error: rzpData?.error?.description || 'Could not start payment with Razorpay.' }, 502);
    }

    await supabase.from('orders').update({ razorpay_order_id: rzpData.id }).eq('id', order.id);

    return jsonResponse({
      razorpay_order_id: rzpData.id,
      amount: amountPaise,
      currency: 'INR',
      key_id: RAZORPAY_KEY_ID
    });
  } catch (e) {
    return jsonResponse({ error: e instanceof Error ? e.message : 'Unexpected error.' }, 500);
  }
});
