// Server-to-server webhook Razorpay calls directly (not the browser),
// configured in the Razorpay Dashboard under Settings -> Webhooks.
// This is the DURABLE source of truth for "did this order get paid" —
// unlike verify-payment (which only fires if the customer's browser
// stays open through Checkout's success callback), Razorpay retries
// this webhook until it gets a 2xx response, so a payment still gets
// recorded even if the customer closes the tab right after paying.
//
// No CORS handling here on purpose — this endpoint is never called
// from a browser, so there's no Origin to allow.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.112.4';

const RAZORPAY_WEBHOOK_SECRET = Deno.env.get('RAZORPAY_WEBHOOK_SECRET')!;
const SUPABASE_URL = Deno.env.get('SUPABASE_URL')!;
const SERVICE_ROLE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

const supabase = createClient(SUPABASE_URL, SERVICE_ROLE_KEY);

async function hmacSha256Hex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message));
  return Array.from(new Uint8Array(sig)).map(b => b.toString(16).padStart(2, '0')).join('');
}

Deno.serve(async (req: Request) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });

  // Verify against the raw request body, not a re-serialized JSON
  // object — Razorpay signs the exact bytes it sent, and re-stringifying
  // parsed JSON is not guaranteed to reproduce them byte-for-byte.
  const rawBody = await req.text();
  const signature = req.headers.get('x-razorpay-signature') || '';
  const expected = await hmacSha256Hex(RAZORPAY_WEBHOOK_SECRET, rawBody);
  if (expected !== signature) {
    return new Response('Invalid signature', { status: 400 });
  }

  let payload: any;
  try { payload = JSON.parse(rawBody); } catch { return new Response('Invalid JSON', { status: 400 }); }

  const event = payload.event;
  if (event === 'payment.captured' || event === 'order.paid') {
    const payment = payload.payload?.payment?.entity;
    const razorpayOrderId = payment?.order_id as string | undefined;
    const razorpayPaymentId = payment?.id as string | undefined;
    let orderNumber = payload.payload?.order?.entity?.receipt as string | undefined;

    if (!orderNumber && razorpayOrderId) {
      const { data } = await supabase.from('orders').select('order_number').eq('razorpay_order_id', razorpayOrderId).single();
      orderNumber = data?.order_number;
    }

    if (orderNumber) {
      await supabase.rpc('mark_order_paid', {
        p_order_number: orderNumber,
        p_razorpay_order_id: razorpayOrderId ?? null,
        p_razorpay_payment_id: razorpayPaymentId ?? null
      });
    }
  }

  // Acknowledge quickly regardless of event type — Razorpay retries on
  // non-2xx, and events we don't act on (e.g. payment.failed) still
  // need a 200 so it doesn't keep resending them forever.
  return new Response('ok', { status: 200 });
});
