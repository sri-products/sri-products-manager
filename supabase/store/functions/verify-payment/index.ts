// Called by the browser right after Razorpay Checkout's success
// callback, so the customer gets instant confirmation instead of
// waiting for the webhook. This is NOT the only source of truth —
// razorpay-webhook (server-to-server, can't be skipped by closing the
// browser tab) is the durable fallback. Both call the same
// mark_order_paid DB function, which is safe to call twice for the
// same order (idempotent).
//
// The whole point of this function: verify the HMAC signature
// ourselves, server-side, using the Razorpay key secret — never trust
// "the browser said the payment succeeded" on its own, since a client
// could fabricate that callback.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.112.4';
import { corsHeaders, jsonResponse, handleOptions } from '../_shared/cors.ts';

const RAZORPAY_KEY_SECRET = Deno.env.get('RAZORPAY_KEY_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  const optionsResponse = handleOptions(req);
  if (optionsResponse) return optionsResponse;
  if (req.method !== 'POST') return jsonResponse({ error: 'Method not allowed' }, 405);

  try {
    const { order_number, razorpay_order_id, razorpay_payment_id, razorpay_signature } = await req.json();
    if (!order_number || !razorpay_order_id || !razorpay_payment_id || !razorpay_signature) {
      return jsonResponse({ error: 'Missing payment details.' }, 400);
    }

    const expected = await hmacSha256Hex(RAZORPAY_KEY_SECRET, `${razorpay_order_id}|${razorpay_payment_id}`);
    if (expected !== razorpay_signature) {
      return jsonResponse({ error: 'Payment signature verification failed.' }, 400);
    }

    const { data, error } = await supabase.rpc('mark_order_paid', {
      p_order_number: order_number,
      p_razorpay_order_id: razorpay_order_id,
      p_razorpay_payment_id: razorpay_payment_id
    });
    if (error) return jsonResponse({ error: error.message }, 500);
    if (!data) return jsonResponse({ error: 'Order not found.' }, 404);

    return jsonResponse({ ok: true });
  } catch (e) {
    return jsonResponse({ error: e instanceof Error ? e.message : 'Unexpected error.' }, 500);
  }
});
