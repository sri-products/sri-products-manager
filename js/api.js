/* ==========================================================================
   Sri Products — API client (Supabase-backed)

   Public interface (call/getToken/setToken/getUser/setUser) is
   UNCHANGED from the Apps Script version, on purpose — app.js was not
   touched for this migration. Internally, every action now maps to a
   Postgres RPC function (see supabase/staff/*.sql) instead of an Apps
   Script POST, and login uses real Supabase Auth instead of a
   hand-rolled Sessions sheet + SHA-256 hash.

   getToken()/setToken() are now just a lightweight "was I logged in"
   flag, not a real credential — the actual session (JWT, refresh,
   expiry) is managed entirely by the Supabase client itself, under
   its own localStorage key. app.js only ever checks truthiness of
   Api.getToken() (`!!Api.getToken()`), never its value, so this is a
   safe simplification, not a compatibility risk.
   ========================================================================== */

const Api = (() => {
  const cfg = window.SRI_CONFIG || {};
  const configured = cfg.SUPABASE_URL && cfg.SUPABASE_URL.indexOf('PASTE_YOUR') !== 0;
  if (!configured) {
    console.error('SRI_CONFIG is not configured — edit js/config.js with your Supabase project URL and anon key.');
  }
  const client = configured ? window.supabase.createClient(cfg.SUPABASE_URL, cfg.SUPABASE_ANON_KEY) : null;
  const EMAIL_DOMAIN = cfg.STAFF_EMAIL_DOMAIN || 'staff.local';

  function getToken() { return localStorage.getItem('sri_token') || null; }
  function setToken(token) { if (token) localStorage.setItem('sri_token', token); else localStorage.removeItem('sri_token'); }
  function getUser() {
    const raw = localStorage.getItem('sri_user');
    return raw ? JSON.parse(raw) : null;
  }
  function setUser(user) { if (user) localStorage.setItem('sri_user', JSON.stringify(user)); else localStorage.removeItem('sri_user'); }

  function usernameToEmail(username) {
    const u = (username || '').trim();
    return u.indexOf('@') !== -1 ? u : u.toLowerCase() + '@' + EMAIL_DOMAIN;
  }

  async function login(username, password) {
    if (!configured) throw new Error('API is not configured. Edit js/config.js with your Supabase project URL and anon key.');
    const email = usernameToEmail(username);
    const { error: authError } = await client.auth.signInWithPassword({ email, password });
    // Deliberately generic message (matches the old behavior) — never
    // reveal whether the username exists vs. the password was wrong.
    if (authError) throw new Error('Invalid username or password.');

    let staff;
    try {
      const { data, error } = await client.rpc('get_current_staff');
      if (error) throw error;
      staff = data; // { userId, name, role }
    } catch (e) {
      await client.auth.signOut();
      throw new Error('This account is not set up as an active staff user.');
    }
    return { token: 'supabase', user: staff };
  }

  async function logout() {
    if (client) await client.auth.signOut();
    return { loggedOut: true };
  }

  // Declarative action -> RPC mapping, one line per Code.gs action.
  // Keeping this as data (rather than a giant switch) makes it easy to
  // audit against apps-script/Code.gs's own doPost() switch — same
  // action names, same parameter shapes coming in from app.js.
  const ACTIONS = {
    getSettings: () => ({ fn: 'get_settings', args: {} }),
    updateSettings: (b) => ({ fn: 'update_settings', args: { p_updates: b.updates } }),

    listCustomers: (b) => ({ fn: 'list_customers', args: { p_search: b.search || null } }),
    createCustomer: (b) => ({ fn: 'create_customer', args: { p_name: b.name } }),
    getCustomerLedger: (b) => ({ fn: 'get_customer_ledger', args: { p_customer_id: b.customerId } }),

    listItems: (b) => ({ fn: 'list_items', args: { p_include_inactive: !!b.includeInactive } }),
    createItem: (b) => ({ fn: 'create_item', args: { p_item: b.item } }),
    updateItem: (b) => ({ fn: 'update_item', args: { p_item_id: b.itemId, p_updates: b.updates } }),
    setItemActive: (b) => ({ fn: 'set_item_active', args: { p_item_id: b.itemId, p_active: !!b.active } }),

    listPrices: (b) => ({ fn: 'list_prices', args: { p_item_id: b.itemId || null } }),
    getCurrentPrices: () => ({ fn: 'get_current_prices', args: {} }),
    addPrice: (b) => ({ fn: 'add_price', args: { p_item_id: b.itemId, p_effective_from: b.effectiveFrom, p_price: b.price } }),
    updatePrice: (b) => ({ fn: 'update_price', args: { p_price_id: b.priceId, p_effective_from: b.effectiveFrom, p_price: b.price } }),
    deletePrice: (b) => ({ fn: 'delete_price', args: { p_price_id: b.priceId } }),

    listBottleAdjustments: (b) => ({ fn: 'list_bottle_adjustments', args: { p_item_id: b.itemId || null } }),
    getCurrentBottleAdjustments: () => ({ fn: 'get_current_bottle_adjustments', args: {} }),
    addBottleAdjustment: (b) => ({ fn: 'add_bottle_adjustment', args: { p_item_id: b.itemId, p_effective_from: b.effectiveFrom, p_amount: b.amount } }),
    updateBottleAdjustment: (b) => ({ fn: 'update_bottle_adjustment', args: { p_adjustment_id: b.adjustmentId, p_effective_from: b.effectiveFrom, p_amount: b.amount } }),
    deleteBottleAdjustment: (b) => ({ fn: 'delete_bottle_adjustment', args: { p_adjustment_id: b.adjustmentId } }),

    getCurrentStock: () => ({ fn: 'get_current_stock', args: {} }),
    getStockMovementHistory: (b) => ({ fn: 'get_stock_movement_history', args: { p_item_id: b.itemId || null } }),
    createStockAdjustment: (b) => ({ fn: 'create_stock_adjustment', args: { p_item_id: b.itemId, p_quantity: b.quantity, p_reason: b.reason } }),
    reverseStockAdjustment: (b) => ({ fn: 'reverse_stock_adjustment', args: { p_movement_id: b.movementId, p_reason: b.reason || '' } }),

    createSale: (b) => ({ fn: 'create_sale', args: { p_payload: b.payload } }),
    updateSale: (b) => ({ fn: 'update_sale', args: { p_sale_id: b.saleId, p_payload: b.payload } }),
    voidSale: (b) => ({ fn: 'void_sale', args: { p_sale_id: b.saleId, p_reason: b.reason } }),
    markSaleAsPaid: (b) => ({ fn: 'mark_sale_as_paid', args: { p_sale_id: b.saleId, p_method: b.method } }),
    listSales: (b) => ({ fn: 'list_sales', args: { p_filters: b.filters || {} } }),
    getSaleDetail: (b) => ({ fn: 'get_sale_detail', args: { p_sale_id: b.saleId } }),

    recordPayment: (b) => ({ fn: 'record_payment', args: { p_payload: b.payload } }),
    listPayments: (b) => ({ fn: 'list_payments', args: { p_filters: b.filters || {} } }),

    createQuotation: (b) => ({ fn: 'create_quotation', args: { p_payload: b.payload } }),
    updateQuotation: (b) => ({ fn: 'update_quotation', args: { p_quotation_id: b.quotationId, p_payload: b.payload } }),
    deleteQuotation: (b) => ({ fn: 'delete_quotation', args: { p_quotation_id: b.quotationId } }),
    listQuotations: (b) => ({ fn: 'list_quotations', args: { p_filters: b.filters || {} } }),
    getQuotationDetail: (b) => ({ fn: 'get_quotation_detail', args: { p_quotation_id: b.quotationId } }),
    updateQuotationStatus: (b) => ({ fn: 'update_quotation_status', args: { p_quotation_id: b.quotationId, p_status: b.status } }),
    convertQuotationToSale: (b) => ({ fn: 'convert_quotation_to_sale', args: { p_quotation_id: b.quotationId, p_payment_amount: Number(b.paymentAmount || 0), p_payment_method: b.paymentMethod } }),

    createProduction: (b) => ({ fn: 'create_production', args: { p_payload: b.payload } }),
    updateProduction: (b) => ({ fn: 'update_production', args: { p_production_id: b.productionId, p_payload: b.payload } }),
    deleteProduction: (b) => ({ fn: 'delete_production', args: { p_production_id: b.productionId } }),
    listProduction: () => ({ fn: 'list_production', args: {} }),
    getProductionDetail: (b) => ({ fn: 'get_production_detail', args: { p_production_id: b.productionId } }),

    getDashboard: () => ({ fn: 'get_dashboard', args: {} })
  };

  async function call(action, params) {
    if (!configured) throw new Error('API is not configured. Edit js/config.js with your Supabase project URL and anon key.');
    const body = params || {};
    if (action === 'login') return login(body.username, body.password);
    if (action === 'logout') return logout();

    const builder = ACTIONS[action];
    if (!builder) throw new Error('Unknown action: ' + action);
    const { fn, args } = builder(body);

    const { data, error } = await client.rpc(fn, args);
    if (error) {
      const msg = error.message || 'Something went wrong.';
      // Matches the original convention (Code.gs's session-expiry
      // message contained "log in again") so this still bounces the
      // user back to the login screen on an expired/invalid session,
      // now covering Supabase/PostgREST's own wording for the same
      // situation too.
      if (/log in again|not authenticated|jwt/i.test(msg)) {
        setToken(null);
        setUser(null);
      }
      throw new Error(msg);
    }
    return data;
  }

  return { call, getToken, setToken, getUser, setUser };
})();
