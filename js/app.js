/* ==========================================================================
   Sri Products — App
   Vanilla JS, hash-based router, no build step.
   ========================================================================== */

const App = (() => {
  const root = document.getElementById('app');
  const State = { items: null, customers: null, priceCache: {}, adjCache: {} };

  // ---------- utilities ----------

  function esc(s) {
    if (s === null || s === undefined) return '';
    return String(s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function money(n) {
    const v = Number(n || 0);
    return '₹' + v.toLocaleString('en-IN', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  }
  function summarizeItems(items) {
    if (!items || !items.length) return 'No items';
    const text = items.map(i => `${i.itemName} ${i.quantity}${i.unit}`).join(', ');
    return text.length > 72 ? esc(text.slice(0, 69)) + '…' : esc(text);
  }
  function fmtDate(d) {
    if (!d) return '—';
    const dt = new Date(d);
    if (isNaN(dt.getTime())) return '—';
    return dt.toLocaleDateString('en-IN', { day: '2-digit', month: 'short', year: 'numeric' });
  }
  function todayInputValue() { return new Date().toISOString().slice(0, 10); }
  function toDateInputValue(d) {
    if (!d) return todayInputValue();
    const dt = new Date(d);
    if (isNaN(dt.getTime())) return todayInputValue();
    return dt.toISOString().slice(0, 10);
  }
  function toast(msg) {
    const el = document.createElement('div');
    el.className = 'toast';
    el.textContent = msg;
    document.body.appendChild(el);
    setTimeout(() => el.remove(), 2600);
  }
  function navigate(hash) { location.hash = hash; }
  function confirmAction(msg) { return window.confirm(msg); }
  function promptText(msg, defaultVal) { return window.prompt(msg, defaultVal || ''); }

  function latestEffective(rows, dateStr, valueKey) {
    const target = new Date(dateStr || todayInputValue());
    const applicable = rows.filter(r => new Date(r.EffectiveFrom) <= target).sort((a, b) => new Date(b.EffectiveFrom) - new Date(a.EffectiveFrom));
    return applicable.length ? Number(applicable[0][valueKey]) : null;
  }

  async function ensureItems() { if (!State.items) State.items = await Api.call('listItems'); return State.items; }
  async function ensureCustomers(search) { State.customers = await Api.call('listCustomers', { search: search || '' }); return State.customers; }
  async function priceRowsFor(itemId) { if (!State.priceCache[itemId]) State.priceCache[itemId] = await Api.call('listPrices', { itemId }); return State.priceCache[itemId]; }
  async function adjRowsFor(itemId) { if (!State.adjCache[itemId]) State.adjCache[itemId] = await Api.call('listBottleAdjustments', { itemId }); return State.adjCache[itemId]; }

  // ---------- shell ----------

  function shell(title, bodyHtml, opts) {
    opts = opts || {};
    const back = opts.back !== false;
    const action = opts.actionLabel ? `<button class="top-action" id="topAction">${esc(opts.actionLabel)}</button>` : '';
    root.innerHTML = `
      <div class="top-bar">
        ${back ? '<button class="back-btn" id="backBtn">&#8592;</button>' : ''}
        <h1>${esc(title)}</h1>
        ${action}
      </div>
      <div class="screen">${bodyHtml}</div>
    `;
    const backBtn = document.getElementById('backBtn');
    if (backBtn) backBtn.onclick = () => history.back();
    if (opts.onAction) { const a = document.getElementById('topAction'); if (a) a.onclick = opts.onAction; }
    renderTabBar(opts.activeTab);
  }

  function renderTabBar(active) {
    document.querySelectorAll('.tab-bar').forEach(el => el.remove());
    if (!Api.getToken()) return;
    const tabs = [
      { key: 'dashboard', label: 'Dashboard', icon: '&#8962;', hash: '#/dashboard' },
      { key: 'sales', label: 'Sales', icon: '&#128179;', hash: '#/sales' },
      { key: 'customers', label: 'Customers', icon: '&#128100;', hash: '#/customers' },
      { key: 'more', label: 'More', icon: '&#8942;', hash: '#/more' }
    ];
    const bar = document.createElement('div');
    bar.className = 'tab-bar';
    bar.innerHTML = tabs.map(t => `<button class="tab-btn ${active === t.key ? 'active' : ''}" data-hash="${t.hash}"><span class="tab-icon">${t.icon}</span>${t.label}</button>`).join('');
    bar.querySelectorAll('.tab-btn').forEach(btn => btn.onclick = () => navigate(btn.dataset.hash));
    document.body.appendChild(bar);
  }

  function errorState(msg) { return `<div class="empty-state"><div class="empty-title">Something went wrong</div><p>${esc(msg)}</p></div>`; }
  function bindGoAttrs() { document.querySelectorAll('[data-go]').forEach(el => el.onclick = () => navigate(el.dataset.go)); }

  function statusBadge(status) {
    const cls = { Draft: 'badge-draft', Sent: 'badge-sent', Accepted: 'badge-accepted', Converted: 'badge-converted', Expired: 'badge-expired', Voided: 'badge-expired', Active: 'badge-accepted' }[status] || 'badge-draft';
    return `<span class="badge ${cls}">${esc(status)}</span>`;
  }

  // ---------- LOGIN ----------

  function screenLogin() {
    root.innerHTML = `
      <div class="login-wrap">
        <div class="login-brand"><div class="brand-name">Sri Products</div><div class="brand-motto">Quality never compromised</div></div>
        <div class="login-card">
          <div class="field"><label>Username</label><input id="loginUser" autocomplete="username"></div>
          <div class="field"><label>Password</label><input id="loginPass" type="password" autocomplete="current-password"></div>
          <button class="btn btn-primary" id="loginBtn">Log in</button>
          <div class="login-error" id="loginErr" style="display:none"></div>
        </div>
      </div>`;
    document.getElementById('loginBtn').onclick = async () => {
      const username = document.getElementById('loginUser').value.trim();
      const password = document.getElementById('loginPass').value;
      const errEl = document.getElementById('loginErr');
      errEl.style.display = 'none';
      if (!username || !password) { errEl.textContent = 'Enter your username and password.'; errEl.style.display = 'block'; return; }
      try {
        const res = await Api.call('login', { username, password });
        Api.setToken(res.token); Api.setUser(res.user);
        navigate('#/dashboard');
      } catch (e) { errEl.textContent = e.message; errEl.style.display = 'block'; }
    };
  }

  // ---------- DASHBOARD ----------

  async function screenDashboard() {
    shell('Sri Products', `<div class="empty-state">Loading…</div>`, { back: false, activeTab: 'dashboard' });
    let d;
    try { d = await Api.call('getDashboard'); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    const user = Api.getUser();
    const stockLow = d.currentStock.filter(s => s.currentStock <= 0 && s.active);
    document.querySelector('.screen').innerHTML = `
      <p class="muted" style="margin-bottom:14px;">Hello, ${esc(user ? user.name : '')}</p>
      <div class="stat-grid">
        <div class="stat-tile"><div class="stat-label">Today's sales</div><div class="stat-value">${money(d.todaySalesTotal)}</div></div>
        <div class="stat-tile"><div class="stat-label">Today's payments</div><div class="stat-value">${money(d.todayPaymentsTotal)}</div></div>
        <div class="stat-tile"><div class="stat-label">This month</div><div class="stat-value">${money(d.monthSalesTotal)}</div></div>
        <div class="stat-tile"><div class="stat-label">Pending</div><div class="stat-value">${money(d.pendingReceivable)}</div></div>
        ${d.creditsOwed > 0 ? `<div class="stat-tile wide"><div class="stat-label">Credit owed to customers (overpayments)</div><div class="stat-value">${money(d.creditsOwed)}</div></div>` : ''}
      </div>
      <div class="section-label">Quick actions</div>
      <div class="quick-actions">
        <button class="quick-action" data-go="#/sales/new"><span class="qa-icon">&#128179;</span>New sale</button>
        <button class="quick-action" data-go="#/quotations/new"><span class="qa-icon">&#128221;</span>New quotation</button>
        <button class="quick-action" data-go="#/payments/new"><span class="qa-icon">&#128176;</span>Record payment</button>
        <button class="quick-action" data-go="#/production/new"><span class="qa-icon">&#9881;</span>New production</button>
      </div>
      ${stockLow.length ? `<div class="section-label">Stock at zero or below</div><div class="panel">${stockLow.map(s => `<div class="list-row"><div class="row-title">${esc(s.name)}</div><div class="amount red">${s.currentStock} ${esc(s.unit)}</div></div>`).join('')}</div>` : ''}
      ${d.productSummary && d.productSummary.length ? `<div class="section-label">Sold this month</div><div class="panel">${d.productSummary.map(p => `<div class="list-row"><div><div class="row-title">${esc(p.name)}</div><div class="row-sub">${p.type === 'FinishedOil' ? 'Oil' : 'Cake by-product'}</div></div><div class="amount">${p.quantitySold} ${esc(p.unit)}</div></div>`).join('')}</div>` : ''}
      <div class="section-label">Recent sales</div>
      <div class="panel">${d.recentSales.length ? d.recentSales.map(s => `
        <div class="list-row" data-go="#/sales/${esc(s.SaleId)}">
          <div><div class="row-title">${esc(s.customerName)} ${s.Status === 'Voided' ? statusBadge('Voided') : ''}</div><div class="row-sub">${fmtDate(s.SaleDate)}</div><div class="row-sub">${summarizeItems(s.items)}</div></div>
          <div class="row-right"><div class="amount">${money(s.GrandTotal)}</div>${s.Status !== 'Voided' && Number(s.Outstanding) > 0 ? `<div class="row-sub" style="color:var(--red-600)">${money(s.Outstanding)} due</div>` : ''}</div>
        </div>`).join('') : '<div class="empty-state">No sales yet.</div>'}</div>
      <div class="section-label">Recent payments</div>
      <div class="panel">${d.recentPayments.length ? d.recentPayments.map(p => `
        <div class="list-row"><div><div class="row-title">${esc(p.PaymentId)}</div><div class="row-sub">${fmtDate(p.PaymentDate)} · ${esc(p.Method)}</div></div><div class="amount green">${money(p.Amount)}</div></div>`).join('') : '<div class="empty-state">No payments yet.</div>'}</div>
    `;
    bindGoAttrs();
  }

  // ---------- MORE ----------

  function screenMore() {
    const user = Api.getUser();
    const isAdmin = user && user.role === 'Admin';
    shell('More', `
      <div class="section-label">Business</div>
      <div class="panel">
        <div class="list-row" data-go="#/quotations"><div class="row-title">Quotations</div><div>&#8250;</div></div>
        <div class="list-row" data-go="#/production"><div class="row-title">Production</div><div>&#8250;</div></div>
        <div class="list-row" data-go="#/inventory"><div class="row-title">Inventory</div><div>&#8250;</div></div>
      </div>
      ${isAdmin ? `<div class="section-label">Admin</div><div class="panel">
        <div class="list-row" data-go="#/admin/products"><div class="row-title">Products</div><div>&#8250;</div></div>
        <div class="list-row" data-go="#/admin/prices"><div class="row-title">Price book</div><div>&#8250;</div></div>
        <div class="list-row" data-go="#/admin/bottle"><div class="row-title">Bottle adjustments</div><div>&#8250;</div></div>
        <div class="list-row" data-go="#/admin/settings"><div class="row-title">Business settings</div><div>&#8250;</div></div>
      </div>` : ''}
      <div class="section-label">Account</div>
      <div class="panel"><div class="list-row" id="logoutRow"><div class="row-title" style="color:var(--red-600)">Log out</div></div></div>
    `, { back: false, activeTab: 'more' });
    bindGoAttrs();
    document.getElementById('logoutRow').onclick = async () => {
      // Best-effort: invalidate the session server-side too, so the
      // token can't still be used if this device is shared/borrowed.
      // Clear local state regardless, even if the request fails
      // (e.g. offline) — the user should never get stuck unable to
      // log out just because the network is down.
      try { await Api.call('logout'); } catch (e) { /* ignore */ }
      Api.setToken(null); Api.setUser(null); navigate('#/login');
    };
  }

  // ---------- CUSTOMERS ----------

  async function screenCustomers() {
    shell('Customers', `<div class="field"><input id="custSearch" placeholder="Search customers…"></div><div class="panel" id="custList"><div class="empty-state">Loading…</div></div>`,
      { back: false, activeTab: 'customers', actionLabel: '+ New', onAction: () => navigate('#/customers/new') });
    async function load(search) {
      const list = document.getElementById('custList');
      try {
        const customers = await ensureCustomers(search);
        list.innerHTML = customers.length ? customers.map(c => `<div class="list-row" data-go="#/customers/${esc(c.CustomerId)}"><div><div class="row-title">${esc(c.Name)}</div><div class="row-sub">${esc(c.CustomerId)}</div></div><div>&#8250;</div></div>`).join('') : '<div class="empty-state">No customers found.</div>';
        bindGoAttrs();
      } catch (e) { list.innerHTML = errorState(e.message); }
    }
    load('');
    let t;
    document.getElementById('custSearch').oninput = (e) => { clearTimeout(t); t = setTimeout(() => load(e.target.value), 250); };
  }

  function screenNewCustomer() {
    shell('New customer', `<div class="field"><label>Customer name</label><input id="custName" placeholder="e.g. Ramesh Traders"></div><button class="btn btn-primary" id="saveCust">Save customer</button>`, { activeTab: 'customers' });
    document.getElementById('saveCust').onclick = async (e) => {
      const name = document.getElementById('custName').value.trim();
      if (!name) { toast('Enter a customer name.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { const c = await Api.call('createCustomer', { name }); State.customers = null; toast('Customer added.'); navigate('#/customers/' + c.CustomerId); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Save customer'; }
    };
  }

  async function screenCustomerDetail(customerId) {
    shell('Customer', `<div class="empty-state">Loading…</div>`, { activeTab: 'customers' });
    let ledger;
    try { ledger = await Api.call('getCustomerLedger', { customerId }); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    const customers = State.customers || await ensureCustomers('');
    const cust = customers.find(c => c.CustomerId === customerId) || { Name: customerId };
    document.querySelector('.top-bar h1').textContent = cust.Name;
    document.querySelector('.screen').innerHTML = `
      <div class="stat-grid">
        <div class="stat-tile"><div class="stat-label">Total sales</div><div class="stat-value">${money(ledger.totalSales)}</div></div>
        <div class="stat-tile"><div class="stat-label">Total paid</div><div class="stat-value">${money(ledger.totalPayments)}</div></div>
        <div class="stat-tile wide"><div class="stat-label">Outstanding</div><div class="stat-value">${money(ledger.outstanding)}</div></div>
      </div>
      <div class="btn-row">
        <button class="btn btn-secondary btn-sm" style="flex:1" data-go="#/sales/new?customer=${esc(customerId)}">New sale</button>
        <button class="btn btn-gold btn-sm" style="flex:1" data-go="#/customers/${esc(customerId)}/pay">Record payment</button>
      </div>
      <div class="section-label">Sales</div>
      <div class="panel">${ledger.sales.length ? ledger.sales.map(s => `
        <div class="list-row" data-go="#/sales/${esc(s.SaleId)}">
          <div><div class="row-title">${fmtDate(s.SaleDate)} ${s.Status === 'Voided' ? statusBadge('Voided') : ''}</div></div>
          <div class="row-right"><div class="amount">${money(s.GrandTotal)}</div>${s.Status !== 'Voided' && Number(s.Outstanding) > 0 ? `<div class="row-sub" style="color:var(--red-600)">${money(s.Outstanding)} due</div>` : (s.Status !== 'Voided' ? '<div class="row-sub" style="color:var(--green-700)">Paid</div>' : '')}</div>
        </div>`).join('') : '<div class="empty-state">No sales yet.</div>'}</div>
      <div class="section-label">Payments</div>
      <div class="panel">${ledger.payments.length ? ledger.payments.map(p => `<div class="list-row"><div><div class="row-title">${esc(p.PaymentId)}</div><div class="row-sub">${fmtDate(p.PaymentDate)} · ${esc(p.Method)}</div></div><div class="amount green">${money(p.Amount)}</div></div>`).join('') : '<div class="empty-state">No payments yet.</div>'}</div>
    `;
    bindGoAttrs();
  }

  // ---------- CUSTOMER NAME AUTOCOMPLETE FIELD ----------

  function customerNameField(id, prefillName) {
    return `
      <div class="field autocomplete-wrap">
        <label>Customer</label>
        <input id="${id}" placeholder="Type a customer name…" value="${esc(prefillName || '')}" autocomplete="off">
        <div class="autocomplete-panel" id="${id}Panel"></div>
        <div class="hint" id="${id}Hint"></div>
      </div>`;
  }

  /**
   * Custom tappable suggestion list (not native <datalist> — iOS Safari
   * barely renders datalist dropdowns at all). Returns a controller so
   * the caller can read what was actually selected/typed at submit time.
   * opts.allowFreeText: true for Sale/Quotation (typed-but-unmatched
   * name creates a new customer on save); false for Payment (must
   * resolve to an existing customer, nothing gets created).
   */
  function attachAutocomplete(id, customers, opts) {
    opts = opts || {};
    const input = document.getElementById(id);
    const panel = document.getElementById(id + 'Panel');
    const hint = document.getElementById(id + 'Hint');
    let selectedId = null;

    function findExact(val) {
      const v = val.trim().toLowerCase();
      return customers.find(c => c.Name.trim().toLowerCase() === v);
    }
    function renderList(val) {
      const q = val.trim().toLowerCase();
      const matches = (q ? customers.filter(c => c.Name.toLowerCase().indexOf(q) !== -1) : customers).slice(0, 8);
      panel.innerHTML = matches.length
        ? matches.map(c => `<div class="autocomplete-item" data-id="${esc(c.CustomerId)}" data-name="${esc(c.Name)}">${esc(c.Name)}</div>`).join('')
        : '<div class="autocomplete-empty">No matching customers</div>';
      panel.classList.add('open');
      panel.querySelectorAll('.autocomplete-item').forEach(el => {
        el.onpointerdown = (ev) => { ev.preventDefault(); select(el.dataset.id, el.dataset.name); };
      });
    }
    function select(id2, name) {
      selectedId = id2; input.value = name; panel.classList.remove('open'); updateHint();
      if (opts.onSelect) opts.onSelect(id2, name);
    }
    function updateHint() {
      if (!hint) return;
      const val = input.value.trim();
      if (!val) { hint.textContent = ''; return; }
      if (selectedId) { hint.textContent = ''; return; }
      const exact = findExact(val);
      if (exact) { selectedId = exact.CustomerId; hint.textContent = ''; if (opts.onSelect) opts.onSelect(exact.CustomerId, exact.Name); return; }
      hint.textContent = opts.allowFreeText ? 'This will be added as a new customer.' : 'No matching customer — select one from the list.';
    }
    input.oninput = () => { selectedId = null; renderList(input.value); updateHint(); };
    input.onfocus = () => renderList(input.value);
    input.onblur = () => { setTimeout(() => panel.classList.remove('open'), 150); updateHint(); };
    if (opts.prefillName) { const exact = findExact(opts.prefillName); if (exact) selectedId = exact.CustomerId; }
    return { getSelectedId: () => selectedId, getSelectedName: () => input.value.trim(), isMatched: () => !!selectedId };
  }

  // ---------- LINE ITEM BUILDER (shared by Sale / Quotation) ----------

  function lineItemTemplate(idx, items, existing) {
    existing = existing || {};
    return `
      <div class="line-item" data-idx="${idx}">
        <div class="line-item-head"><span class="li-name">Item ${idx + 1}</span><button class="li-remove" data-remove="${idx}">Remove</button></div>
        <div class="field"><label>Product</label>
          <select class="li-item" data-idx="${idx}">
            <option value="">Select…</option>
            ${items.map(i => `<option value="${esc(i.ItemId)}" ${i.ItemId === existing.itemId ? 'selected' : ''}>${esc(i.Name)} (${esc(i.Unit)})</option>`).join('')}
          </select>
        </div>
        <div class="line-item-row"><div class="field"><label>Quantity</label><input type="number" min="0" step="0.01" class="li-qty" data-idx="${idx}" value="${existing.quantity || ''}"></div></div>
        <div class="checkbox-row"><input type="checkbox" class="li-bottle" data-idx="${idx}" id="bottle${idx}" ${existing.ownBottle ? 'checked' : ''}><label for="bottle${idx}">Customer's own bottle</label></div>
        <div class="line-item-amount muted">Rate: <span class="li-rate">—</span> · Amount: <span class="li-amount">—</span></div>
      </div>`;
  }

  async function recalcLine(container, idx, dateStr) {
    const row = container.querySelector(`.line-item[data-idx="${idx}"]`);
    const itemId = row.querySelector('.li-item').value;
    const qty = Number(row.querySelector('.li-qty').value || 0);
    const ownBottle = row.querySelector('.li-bottle').checked;
    const rateEl = row.querySelector('.li-rate');
    const amtEl = row.querySelector('.li-amount');
    if (!itemId) { rateEl.textContent = '—'; amtEl.textContent = '—'; return null; }
    try {
      const prices = await priceRowsFor(itemId);
      const baseRate = latestEffective(prices, dateStr, 'Price');
      if (baseRate === null) { rateEl.textContent = 'no price set'; amtEl.textContent = '—'; return null; }
      let adj = 0;
      if (ownBottle) { const adjRows = await adjRowsFor(itemId); adj = latestEffective(adjRows, dateStr, 'Amount') || 0; }
      const finalRate = Math.round((baseRate - adj) * 100) / 100;
      const amount = Math.round(finalRate * qty * 100) / 100;
      rateEl.textContent = money(finalRate); amtEl.textContent = money(amount);
      return { itemId, quantity: qty, ownBottle, amount };
    } catch (e) { rateEl.textContent = 'error'; return null; }
  }

  async function recalcTotals(container, dateStr, totalsEl) {
    const rows = container.querySelectorAll('.line-item');
    let subtotal = 0;
    for (const row of rows) { const result = await recalcLine(container, Number(row.dataset.idx), dateStr); if (result) subtotal += result.amount; }
    totalsEl.innerHTML = `
      <div class="totals-row"><span>Subtotal</span><span>${money(subtotal)}</span></div>
      <div class="totals-row grand"><span>Total</span><span>${money(subtotal)}</span></div>
      <p class="muted" style="color:#c7cbe0;margin-top:4px;">Tax (if GST is enabled) is calculated on save.</p>`;
  }

  function collectLineItems(container) {
    const items = [];
    container.querySelectorAll('.line-item').forEach(row => {
      const itemId = row.querySelector('.li-item').value;
      const qty = Number(row.querySelector('.li-qty').value || 0);
      const ownBottle = row.querySelector('.li-bottle').checked;
      if (itemId && qty > 0) items.push({ itemId, quantity: qty, ownBottle });
    });
    return items;
  }

  function bindLineHost(lineHost, dateInputId, totalsEl, items) {
    function bindRowEvents() {
      lineHost.querySelectorAll('.li-item, .li-qty, .li-bottle').forEach(el => el.onchange = () => recalcTotals(lineHost, document.getElementById(dateInputId).value, totalsEl));
      lineHost.querySelectorAll('[data-remove]').forEach(btn => btn.onclick = () => { lineHost.querySelector(`.line-item[data-idx="${btn.dataset.remove}"]`).remove(); recalcTotals(lineHost, document.getElementById(dateInputId).value, totalsEl); });
    }
    return bindRowEvents;
  }

  // ---------- SALE FORM (create + edit share this) ----------

  async function renderSaleForm(mode, prefillCustomerId, existingSaleId) {
    shell(mode === 'edit' ? 'Edit sale' : 'New sale', `<div class="empty-state">Loading…</div>`, { activeTab: 'sales' });
    const items = await ensureItems();
    const customers = await ensureCustomers('');
    let existing = null;
    if (mode === 'edit') {
      existing = await Api.call('getSaleDetail', { saleId: existingSaleId });
    }
    const saleDateVal = existing ? toDateInputValue(existing.sale.SaleDate) : todayInputValue();
    const custName = existing && existing.customer ? existing.customer.Name : '';

    document.querySelector('.screen').innerHTML = `
      ${customerNameField('saleCustomer', custName)}
      <div class="field"><label>Sale date</label><input type="date" id="saleDate" value="${saleDateVal}"></div>
      <div class="section-label">Items</div>
      <div id="lineItems"></div>
      <button class="btn btn-secondary btn-sm" id="addLine">+ Add item</button>
      <div class="totals-panel" id="totals"></div>
      ${mode === 'new' ? `
      <div class="section-label">Payment</div>
      <div class="field"><label>Amount received now (optional)</label><input type="number" min="0" step="0.01" id="amountReceived" placeholder="0.00"></div>
      <div class="field"><label>Payment method</label><select id="paymentMethod"><option>Cash</option><option>UPI</option><option>Bank Transfer</option><option>Cheque</option></select></div>
      ` : `<p class="muted" style="margin-top:10px;">Editing items only — payments already recorded against this sale are unaffected. Use "Record payment" from the sale to add more.</p>`}
      <button class="btn btn-primary" id="saveSale" style="margin-top:8px;">${mode === 'edit' ? 'Save changes' : 'Save sale'}</button>
    `;

    attachAutocomplete('saleCustomer', customers, { allowFreeText: true, prefillName: custName });

    const lineHost = document.getElementById('lineItems');
    const totalsEl = document.getElementById('totals');
    const bindRowEvents = bindLineHost(lineHost, 'saleDate', totalsEl, items);
    let lineCount = 0;

    function addLine(existingLine) {
      const idx = lineCount++;
      lineHost.insertAdjacentHTML('beforeend', lineItemTemplate(idx, items, existingLine));
      bindRowEvents();
    }
    document.getElementById('addLine').onclick = () => addLine();
    document.getElementById('saleDate').onchange = () => recalcTotals(lineHost, document.getElementById('saleDate').value, totalsEl);

    if (existing && existing.items.length) {
      existing.items.forEach(li => addLine({ itemId: li.ItemId, quantity: li.Quantity, ownBottle: Number(li.BottleAdjustment) > 0 }));
    } else {
      addLine();
    }
    recalcTotals(lineHost, document.getElementById('saleDate').value, totalsEl);

    document.getElementById('saveSale').onclick = async (e) => {
      const customerName = document.getElementById('saleCustomer').value.trim();
      if (!customerName) { toast('Enter a customer name.'); return; }
      const lineItemsPayload = collectLineItems(lineHost);
      if (lineItemsPayload.length === 0) { toast('Add at least one item.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try {
        if (mode === 'edit') {
          const res = await Api.call('updateSale', { saleId: existingSaleId, payload: { customerName, saleDate: document.getElementById('saleDate').value, items: lineItemsPayload } });
          toast('Sale updated.');
          navigate('#/sales/' + res.sale.SaleId);
        } else {
          const res = await Api.call('createSale', { payload: { customerName, saleDate: document.getElementById('saleDate').value, items: lineItemsPayload, amountReceived: Number(document.getElementById('amountReceived').value || 0), paymentMethod: document.getElementById('paymentMethod').value } });
          toast('Sale saved.');
          navigate('#/sales/' + res.sale.SaleId);
        }
      } catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = mode === 'edit' ? 'Save changes' : 'Save sale'; }
    };
  }

  // ---------- SALES LIST / DETAIL ----------

  function saleBucket(s) {
    if (s.Status === 'Voided') return 'voided';
    const outstanding = Number(s.Outstanding || 0);
    if (outstanding <= 0) return 'paid';
    if (Number(s.AmountReceived || 0) <= 0) return 'unpaid';
    return 'partial';
  }

  async function screenSales() {
    shell('Sales', `
      <div class="field"><input id="salesSearch" placeholder="Search by customer…"></div>
      <div class="filter-row" id="salesFilters">
        <button class="chip active" data-filter="all">All</button>
        <button class="chip" data-filter="unpaid">Unpaid</button>
        <button class="chip" data-filter="partial">Partially paid</button>
        <button class="chip" data-filter="paid">Paid</button>
      </div>
      <div class="panel" id="salesList"><div class="empty-state">Loading…</div></div>
    `, { back: false, activeTab: 'sales', actionLabel: '+ New', onAction: () => navigate('#/sales/new') });

    let allSales = [];
    let activeFilter = 'all';

    function render() {
      const q = document.getElementById('salesSearch').value.trim().toLowerCase();
      const filtered = allSales.filter(s => {
        if (activeFilter !== 'all' && saleBucket(s) !== activeFilter) return false;
        if (q && s.customerName.toLowerCase().indexOf(q) === -1) return false;
        return true;
      });
      document.getElementById('salesList').innerHTML = filtered.length ? filtered.map(s => `
        <div class="list-row" data-go="#/sales/${esc(s.SaleId)}">
          <div>
            <div class="row-title">${esc(s.customerName)} ${s.Status === 'Voided' ? statusBadge('Voided') : ''}</div>
            <div class="row-sub">${fmtDate(s.SaleDate)}</div>
            <div class="row-sub">${summarizeItems(s.items)}</div>
          </div>
          <div class="row-right"><div class="amount">${money(s.GrandTotal)}</div>${s.Status === 'Voided' ? '' : (Number(s.Outstanding) > 0 ? `<div class="row-sub" style="color:var(--red-600)">${money(s.Outstanding)} due</div>` : '<div class="row-sub" style="color:var(--green-700)">Paid</div>')}</div>
        </div>`).join('') : '<div class="empty-state"><div class="empty-title">No matching sales</div></div>';
      bindGoAttrs();
    }

    try {
      allSales = await Api.call('listSales', {});
      render();
    } catch (e) { document.getElementById('salesList').innerHTML = errorState(e.message); return; }

    document.getElementById('salesSearch').oninput = render;
    document.querySelectorAll('#salesFilters .chip').forEach(chip => chip.onclick = () => {
      document.querySelectorAll('#salesFilters .chip').forEach(c => c.classList.remove('active'));
      chip.classList.add('active');
      activeFilter = chip.dataset.filter;
      render();
    });
  }

  function screenNewSale(prefillCustomerId) { return renderSaleForm('new', prefillCustomerId); }
  function screenEditSale(saleId) { return renderSaleForm('edit', null, saleId); }

  async function screenSaleDetail(saleId) {
    shell('Sale', `<div class="empty-state">Loading…</div>`, { activeTab: 'sales' });
    let detail;
    try { detail = await Api.call('getSaleDetail', { saleId }); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    const s = detail.sale;
    const isVoided = s.Status === 'Voided';
    document.querySelector('.top-bar h1').textContent = s.SaleId;
    document.querySelector('.screen').innerHTML = `
      <div class="receipt-header"><div class="rh-name">Sri Products</div><div class="rh-motto">Quality never compromised</div></div>
      <div class="panel" style="padding:14px;">
        <p><strong>${esc(detail.customer ? detail.customer.Name : s.CustomerId)}</strong> ${isVoided ? statusBadge('Voided') : ''}</p>
        <p class="muted">${esc(s.SaleId)} · ${fmtDate(s.SaleDate)}</p>
        ${isVoided ? `<p class="muted" style="color:var(--red-600)">Voided: ${esc(s.VoidReason)}</p>` : ''}
      </div>
      <div class="section-label">Items</div>
      <div class="panel">${detail.items.map(i => `
        <div class="list-row"><div><div class="row-title">${esc(i.itemName)}</div><div class="row-sub">${i.Quantity} ${esc(i.Unit)} × ${money(i.FinalRate)}${Number(i.BottleAdjustment) > 0 ? ' (own bottle)' : ''}</div></div><div class="amount">${money(i.Amount)}</div></div>`).join('')}</div>
      <div class="totals-panel">
        <div class="totals-row"><span>Subtotal</span><span>${money(s.Subtotal)}</span></div>
        ${Number(s.TaxAmount) > 0 ? `<div class="totals-row"><span>Tax</span><span>${money(s.TaxAmount)}</span></div>` : ''}
        <div class="totals-row grand"><span>Total</span><span>${money(s.GrandTotal)}</span></div>
        <div class="totals-row"><span>Received</span><span>${money(s.AmountReceived)}</span></div>
        <div class="totals-row"><span>Outstanding</span><span>${money(isVoided ? 0 : s.Outstanding)}</span></div>
      </div>
      <div class="btn-row no-print">
        <button class="btn btn-secondary" id="printBtn">Print / Share PDF</button>
        ${!isVoided && Number(s.Outstanding) > 0 ? `<button class="btn btn-gold" data-go="#/customers/${esc(s.CustomerId)}/pay?sale=${esc(s.SaleId)}">Record payment</button>` : ''}
      </div>
      ${!isVoided && Number(s.Outstanding) > 0 ? `<div class="btn-row no-print"><button class="btn btn-secondary" id="markPaidBtn">Mark as paid (${money(s.Outstanding)})</button></div>` : ''}
      ${!isVoided ? `<div class="btn-row no-print">
        <button class="btn btn-secondary" data-go="#/sales/${esc(s.SaleId)}/edit">Edit</button>
        <button class="btn btn-danger" id="voidBtn">Void sale</button>
      </div>` : ''}
    `;
    bindGoAttrs();
    document.getElementById('printBtn').onclick = () => window.print();
    const markPaidBtn = document.getElementById('markPaidBtn');
    if (markPaidBtn) markPaidBtn.onclick = async () => {
      if (!confirmAction('Mark this sale as fully paid? This records a payment of ' + money(s.Outstanding) + '.')) return;
      try { await Api.call('markSaleAsPaid', { saleId, method: 'Cash' }); toast('Sale marked as paid.'); screenSaleDetail(saleId); }
      catch (err) { toast(err.message); }
    };
    const voidBtn = document.getElementById('voidBtn');
    if (voidBtn) voidBtn.onclick = async () => {
      const reason = promptText('Reason for voiding this sale? (this reverses its stock impact)');
      if (reason === null) return;
      if (!reason.trim()) { toast('A reason is required.'); return; }
      try { await Api.call('voidSale', { saleId, reason: reason.trim() }); toast('Sale voided.'); screenSaleDetail(saleId); }
      catch (err) { toast(err.message); }
    };
  }

  // ---------- PAYMENTS ----------

  async function screenRecordPayment(prefillCustomerId, prefillSaleId) {
    shell('Record payment', `<div class="empty-state">Loading…</div>`, { activeTab: 'customers' });
    const customers = await ensureCustomers('');
    let prefillName = '';
    if (prefillCustomerId) { const c = customers.find(c => c.CustomerId === prefillCustomerId); if (c) prefillName = c.Name; }

    document.querySelector('.screen').innerHTML = `
      ${customerNameField('payCustomer', prefillName)}
      <div class="field"><label>Amount</label><input type="number" min="0" step="0.01" id="payAmount"></div>
      <div class="field"><label>Date</label><input type="date" id="payDate" value="${todayInputValue()}"></div>
      <div class="field"><label>Method</label><select id="payMethod"><option>Cash</option><option>UPI</option><option>Bank Transfer</option><option>Cheque</option></select></div>
      <div class="field"><label>Notes (optional)</label><textarea id="payNotes" rows="2"></textarea></div>
      <div id="allocSection"></div>
      <button class="btn btn-primary" id="savePayment" style="margin-top:8px;">Save payment</button>
    `;

    let outstandingSales = [];
    let manuallyEdited = false;

    async function loadOutstanding(customerId) {
      const allocHost = document.getElementById('allocSection');
      allocHost.innerHTML = `<p class="muted">Loading outstanding sales…</p>`;
      manuallyEdited = false;
      try {
        const ledger = await Api.call('getCustomerLedger', { customerId });
        outstandingSales = ledger.sales
          .filter(s => s.Status !== 'Voided' && Number(s.Outstanding) > 0)
          .sort((a, b) => new Date(a.SaleDate) - new Date(b.SaleDate)); // oldest first, for the default split
        if (!outstandingSales.length) { allocHost.innerHTML = ''; return; }
        allocHost.innerHTML = `
          <div class="section-label">Apply to outstanding sales</div>
          <div class="panel">${outstandingSales.map(s => `
            <div class="alloc-row" data-alloc-row="${esc(s.SaleId)}">
              <div><div class="row-title">${fmtDate(s.SaleDate)}${s.SaleId === prefillSaleId ? ' (this sale)' : ''}</div><div class="row-sub">Total ${money(s.GrandTotal)} · Due ${money(s.Outstanding)}</div></div>
              <input type="number" min="0" step="0.01" class="alloc-input" data-sale="${esc(s.SaleId)}" data-due="${s.Outstanding}" value="0">
            </div>`).join('')}</div>
          <p class="muted" id="allocRemain" style="margin-top:8px;"></p>
        `;
        allocHost.querySelectorAll('.alloc-input').forEach(inp => inp.oninput = () => { manuallyEdited = true; updateRemainLabel(); });
        if (prefillSaleId && !document.getElementById('payAmount').value) {
          const target = outstandingSales.find(s => s.SaleId === prefillSaleId);
          if (target) document.getElementById('payAmount').value = target.Outstanding;
        }
        applySplit();
      } catch (err) { allocHost.innerHTML = ''; toast(err.message); }
    }

    function applySplit() {
      if (manuallyEdited) { updateRemainLabel(); return; }
      let remaining = round2(Number(document.getElementById('payAmount').value || 0));
      outstandingSales.forEach(s => {
        const input = document.querySelector(`.alloc-input[data-sale="${CSS.escape(s.SaleId)}"]`);
        if (!input) return;
        const due = Number(s.Outstanding);
        const take = remaining > 0 ? Math.min(due, remaining) : 0;
        input.value = take > 0 ? take : '';
        remaining = round2(remaining - take);
      });
      updateRemainLabel();
    }

    function updateRemainLabel() {
      const el = document.getElementById('allocRemain');
      if (!el) return;
      const total = round2(Number(document.getElementById('payAmount').value || 0));
      const allocated = round2(Array.from(document.querySelectorAll('.alloc-input')).reduce((s, i) => s + Number(i.value || 0), 0));
      const remain = round2(total - allocated);
      if (remain < -0.004) { el.textContent = `Over-allocated by ${money(-remain)} — reduce the amounts above.`; el.style.color = 'var(--red-600)'; }
      else if (remain > 0.004) { el.textContent = `${money(remain)} left unallocated — recorded as an advance/credit.`; el.style.color = ''; }
      else { el.textContent = 'Fully allocated.'; el.style.color = 'var(--green-700)'; }
    }
    function round2(n) { return Math.round((Number(n) + Number.EPSILON) * 100) / 100; }

    const autocomplete = attachAutocomplete('payCustomer', customers, {
      allowFreeText: false,
      prefillName: prefillName,
      onSelect: (id) => loadOutstanding(id)
    });
    if (prefillCustomerId) loadOutstanding(prefillCustomerId);
    document.getElementById('payAmount').oninput = applySplit;

    document.getElementById('savePayment').onclick = async (e) => {
      const customerId = autocomplete.getSelectedId();
      if (!customerId) { toast('Select an existing customer from the suggestions.'); return; }
      const amount = Number(document.getElementById('payAmount').value || 0);
      if (!(amount > 0)) { toast('Enter an amount greater than zero.'); return; }
      const allocations = Array.from(document.querySelectorAll('.alloc-input'))
        .map(i => ({ saleId: i.dataset.sale, amount: Number(i.value || 0) }))
        .filter(a => a.amount > 0);
      const allocatedTotal = round2(allocations.reduce((s, a) => s + a.amount, 0));
      if (allocatedTotal - amount > 0.01) { toast('The amounts applied to sales add up to more than the payment amount.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try {
        await Api.call('recordPayment', { payload: { customerId, amount, paymentDate: document.getElementById('payDate').value, method: document.getElementById('payMethod').value, notes: document.getElementById('payNotes').value.trim(), allocations } });
        toast('Payment recorded.');
        navigate('#/customers/' + customerId);
      } catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Save payment'; }
    };
  }

  // ---------- QUOTATIONS ----------

  async function screenQuotations() {
    shell('Quotations', `<div class="panel" id="quoteList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more', actionLabel: '+ New', onAction: () => navigate('#/quotations/new') });
    try {
      const quotes = await Api.call('listQuotations', {});
      const customers = await ensureCustomers('');
      const nameOf = id => { const c = customers.find(c => c.CustomerId === id); return c ? c.Name : id; };
      document.getElementById('quoteList').innerHTML = quotes.length ? quotes.map(q => `
        <div class="list-row" data-go="#/quotations/${esc(q.QuotationId)}">
          <div><div class="row-title">${esc(nameOf(q.CustomerId))}</div><div class="row-sub">${esc(q.QuotationId)} · ${fmtDate(q.QuotationDate)}</div></div>
          <div class="row-right"><div class="amount">${money(q.GrandTotal)}</div>${statusBadge(q.Status)}</div>
        </div>`).join('') : '<div class="empty-state"><div class="empty-title">No quotations yet</div></div>';
      bindGoAttrs();
    } catch (e) { document.getElementById('quoteList').innerHTML = errorState(e.message); }
  }

  async function renderQuotationForm(mode, existingQuotationId) {
    shell(mode === 'edit' ? 'Edit quotation' : 'New quotation', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await ensureItems();
    const customers = await ensureCustomers('');
    let existing = null;
    if (mode === 'edit') existing = await Api.call('getQuotationDetail', { quotationId: existingQuotationId });
    const dateVal = existing ? toDateInputValue(existing.quotation.QuotationDate) : todayInputValue();
    const validVal = existing && existing.quotation.ValidUntil ? toDateInputValue(existing.quotation.ValidUntil) : '';
    const custName = existing && existing.customer ? existing.customer.Name : '';

    document.querySelector('.screen').innerHTML = `
      ${customerNameField('qCustomer', custName)}
      <div class="field"><label>Quotation date</label><input type="date" id="qDate" value="${dateVal}"></div>
      <div class="field"><label>Valid until (optional)</label><input type="date" id="qValidUntil" value="${validVal}"></div>
      <div class="section-label">Items</div>
      <div id="qLineItems"></div>
      <button class="btn btn-secondary btn-sm" id="qAddLine">+ Add item</button>
      <div class="totals-panel" id="qTotals"></div>
      <button class="btn btn-primary" id="saveQuote" style="margin-top:14px;">${mode === 'edit' ? 'Save changes' : 'Save quotation'}</button>
    `;
    attachAutocomplete('qCustomer', customers, { allowFreeText: true, prefillName: custName });

    const lineHost = document.getElementById('qLineItems');
    const totalsEl = document.getElementById('qTotals');
    const bindRowEvents = bindLineHost(lineHost, 'qDate', totalsEl, items);
    let lineCount = 0;
    function addLine(existingLine) { const idx = lineCount++; lineHost.insertAdjacentHTML('beforeend', lineItemTemplate(idx, items, existingLine)); bindRowEvents(); }
    document.getElementById('qAddLine').onclick = () => addLine();
    document.getElementById('qDate').onchange = () => recalcTotals(lineHost, document.getElementById('qDate').value, totalsEl);

    if (existing && existing.items.length) existing.items.forEach(li => addLine({ itemId: li.ItemId, quantity: li.Quantity, ownBottle: Number(li.BottleAdjustment) > 0 }));
    else addLine();
    recalcTotals(lineHost, document.getElementById('qDate').value, totalsEl);

    document.getElementById('saveQuote').onclick = async (e) => {
      const customerName = document.getElementById('qCustomer').value.trim();
      if (!customerName) { toast('Enter a customer name.'); return; }
      const lineItemsPayload = collectLineItems(lineHost);
      if (lineItemsPayload.length === 0) { toast('Add at least one item.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try {
        if (mode === 'edit') {
          const res = await Api.call('updateQuotation', { quotationId: existingQuotationId, payload: { customerName, quotationDate: document.getElementById('qDate').value, validUntil: document.getElementById('qValidUntil').value || null, items: lineItemsPayload } });
          toast('Quotation updated.');
          navigate('#/quotations/' + res.quotation.QuotationId);
        } else {
          const res = await Api.call('createQuotation', { payload: { customerName, quotationDate: document.getElementById('qDate').value, validUntil: document.getElementById('qValidUntil').value || null, items: lineItemsPayload } });
          toast('Quotation saved.');
          navigate('#/quotations/' + res.quotation.QuotationId);
        }
      } catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = mode === 'edit' ? 'Save changes' : 'Save quotation'; }
    };
  }

  function screenNewQuotation() { return renderQuotationForm('new'); }
  function screenEditQuotation(quotationId) { return renderQuotationForm('edit', quotationId); }

  async function screenQuotationDetail(quotationId) {
    shell('Quotation', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    let detail;
    try { detail = await Api.call('getQuotationDetail', { quotationId }); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    const q = detail.quotation;
    const editable = q.Status !== 'Converted';
    document.querySelector('.top-bar h1').textContent = q.QuotationId;
    document.querySelector('.screen').innerHTML = `
      <div class="panel" style="padding:14px;"><p><strong>${esc(detail.customer ? detail.customer.Name : q.CustomerId)}</strong> ${statusBadge(q.Status)}</p><p class="muted">${fmtDate(q.QuotationDate)}${q.ValidUntil ? ' · valid until ' + fmtDate(q.ValidUntil) : ''}</p></div>
      <div class="section-label">Items</div>
      <div class="panel">${detail.items.map(i => `<div class="list-row"><div><div class="row-title">${esc(i.itemName)}</div><div class="row-sub">${i.Quantity} ${esc(i.Unit)} × ${money(i.FinalRate)}</div></div><div class="amount">${money(i.Amount)}</div></div>`).join('')}</div>
      <div class="totals-panel">
        <div class="totals-row"><span>Subtotal</span><span>${money(q.Subtotal)}</span></div>
        ${Number(q.TaxAmount) > 0 ? `<div class="totals-row"><span>Tax</span><span>${money(q.TaxAmount)}</span></div>` : ''}
        <div class="totals-row grand"><span>Total</span><span>${money(q.GrandTotal)}</span></div>
      </div>
      <div class="btn-row no-print">
        <button class="btn btn-secondary" id="printBtn">Print</button>
        ${editable && q.Status !== 'Expired' ? `<button class="btn btn-gold" data-go="#/quotations/${esc(q.QuotationId)}/convert">Convert to sale</button>` : ''}
      </div>
      ${editable ? `<div class="btn-row no-print">
        <button class="btn btn-secondary" data-go="#/quotations/${esc(q.QuotationId)}/edit">Edit</button>
        <button class="btn btn-danger" id="deleteQuoteBtn">Delete</button>
      </div>` : ''}
    `;
    bindGoAttrs();
    document.getElementById('printBtn').onclick = () => window.print();
    const delBtn = document.getElementById('deleteQuoteBtn');
    if (delBtn) delBtn.onclick = async () => {
      if (!confirmAction('Delete this quotation? This cannot be undone.')) return;
      try { await Api.call('deleteQuotation', { quotationId }); toast('Quotation deleted.'); navigate('#/quotations'); }
      catch (err) { toast(err.message); }
    };
  }

  async function screenConvertQuotation(quotationId) {
    shell('Convert to sale', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    let detail;
    try { detail = await Api.call('getQuotationDetail', { quotationId }); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    document.querySelector('.screen').innerHTML = `
      <p class="muted">Converting ${esc(quotationId)} for <strong>${esc(detail.customer ? detail.customer.Name : detail.quotation.CustomerId)}</strong>, total ${money(detail.quotation.GrandTotal)}.</p>
      <div class="field"><label>Amount received now (optional)</label><input type="number" min="0" step="0.01" id="convAmount"></div>
      <div class="field"><label>Payment method</label><select id="convMethod"><option>Cash</option><option>UPI</option><option>Bank Transfer</option><option>Cheque</option></select></div>
      <button class="btn btn-primary" id="convertBtn">Confirm conversion</button>
    `;
    document.getElementById('convertBtn').onclick = async (e) => {
      e.target.disabled = true; e.target.textContent = 'Converting…';
      try {
        const res = await Api.call('convertQuotationToSale', { quotationId, paymentAmount: Number(document.getElementById('convAmount').value || 0), paymentMethod: document.getElementById('convMethod').value });
        toast(res.stockWarnings && res.stockWarnings.length ? 'Converted — but stock ran short on: ' + res.stockWarnings.join('; ') : 'Converted to sale.');
        navigate('#/sales/' + res.sale.SaleId);
      } catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Confirm conversion'; }
    };
  }

  // ---------- PRODUCTION ----------

  async function screenProduction() {
    shell('Production', `<div class="panel" id="prodList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more', actionLabel: '+ New', onAction: () => navigate('#/production/new') });
    try {
      const rows = await Api.call('listProduction');
      document.getElementById('prodList').innerHTML = rows.length ? rows.map(p => `
        <div class="list-row" data-go="#/production/${esc(p.productionId)}">
          <div><div class="row-title">${fmtDate(p.date)}</div><div class="row-sub">In: ${p.inputs.map(i => `${i.itemName} ${i.quantity}`).join(', ') || '—'}</div><div class="row-sub">Out: ${p.outputs.map(o => `${o.itemName} ${o.quantity}`).join(', ') || '—'}</div></div>
          <div>&#8250;</div>
        </div>`).join('') : '<div class="empty-state"><div class="empty-title">No production entries yet</div></div>';
      bindGoAttrs();
    } catch (e) { document.getElementById('prodList').innerHTML = errorState(e.message); }
  }

  async function screenProductionDetail(productionId) {
    shell('Production entry', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    let p;
    try { p = await Api.call('getProductionDetail', { productionId }); } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); return; }
    const user = Api.getUser();
    document.querySelector('.screen').innerHTML = `
      <div class="panel" style="padding:14px;"><p><strong>${fmtDate(p.date)}</strong></p>${p.notes ? `<p class="muted">${esc(p.notes)}</p>` : ''}</div>
      <div class="section-label">Raw materials consumed</div>
      <div class="panel">${p.inputs.map(i => `<div class="list-row"><div class="row-title">${esc(i.itemName)}</div><div class="amount red">-${i.quantity}</div></div>`).join('') || '<div class="empty-state">None.</div>'}</div>
      <div class="section-label">Outputs produced</div>
      <div class="panel">${p.outputs.map(o => `<div class="list-row"><div class="row-title">${esc(o.itemName)}</div><div class="amount green">+${o.quantity}</div></div>`).join('') || '<div class="empty-state">None.</div>'}</div>
      <div class="btn-row no-print">
        <button class="btn btn-secondary" data-go="#/production/${esc(productionId)}/edit">Edit</button>
        ${user && user.role === 'Admin' ? `<button class="btn btn-danger" id="deleteProdBtn">Delete</button>` : ''}
      </div>
    `;
    bindGoAttrs();
    const delBtn = document.getElementById('deleteProdBtn');
    if (delBtn) delBtn.onclick = async () => {
      if (!confirmAction('Delete this production entry? Its stock impact will be reversed.')) return;
      try { await Api.call('deleteProduction', { productionId }); toast('Production entry deleted.'); navigate('#/production'); }
      catch (err) { toast(err.message); }
    };
  }

  function prodLineTemplate(idx, items, kind, existing) {
    existing = existing || {};
    return `
      <div class="line-item" data-${kind}-idx="${idx}">
        <div class="line-item-head"><span class="li-name">${kind === 'input' ? 'Raw material' : 'Output'} ${idx + 1}</span><button class="li-remove" data-remove-${kind}="${idx}">Remove</button></div>
        <div class="field"><select class="p-${kind}-item"><option value="">Select item…</option>${items.map(i => `<option value="${esc(i.ItemId)}" ${i.ItemId === existing.itemId ? 'selected' : ''}>${esc(i.Name)} (${esc(i.Unit)})</option>`).join('')}</select></div>
        <div class="field"><input type="number" min="0" step="0.01" class="p-${kind}-qty" placeholder="Quantity" value="${existing.quantity || ''}"></div>
      </div>`;
  }

  async function renderProductionForm(mode, existingProductionId) {
    shell(mode === 'edit' ? 'Edit production' : 'New production', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await ensureItems();
    let existing = null;
    if (mode === 'edit') existing = await Api.call('getProductionDetail', { productionId: existingProductionId });

    document.querySelector('.screen').innerHTML = `
      <div class="field"><label>Date</label><input type="date" id="pDate" value="${existing ? toDateInputValue(existing.date) : todayInputValue()}"></div>
      <div class="field"><label>Notes (optional)</label><textarea id="pNotes" rows="2">${esc(existing ? existing.notes : '')}</textarea></div>
      <div class="section-label">Raw materials consumed</div>
      <div id="pInputs"></div>
      <button class="btn btn-secondary btn-sm" id="addInput">+ Add input</button>
      <div class="section-label">Outputs produced</div>
      <div id="pOutputs"></div>
      <button class="btn btn-secondary btn-sm" id="addOutput">+ Add output</button>
      <button class="btn btn-primary" id="saveProd" style="margin-top:16px;">${mode === 'edit' ? 'Save changes' : 'Save production entry'}</button>
    `;
    const inputHost = document.getElementById('pInputs');
    const outputHost = document.getElementById('pOutputs');
    let inCount = 0, outCount = 0;
    function addInput(existingLine) { const idx = inCount++; inputHost.insertAdjacentHTML('beforeend', prodLineTemplate(idx, items, 'input', existingLine)); inputHost.querySelector(`[data-remove-input="${idx}"]`).onclick = () => inputHost.querySelector(`[data-input-idx="${idx}"]`).remove(); }
    function addOutput(existingLine) { const idx = outCount++; outputHost.insertAdjacentHTML('beforeend', prodLineTemplate(idx, items, 'output', existingLine)); outputHost.querySelector(`[data-remove-output="${idx}"]`).onclick = () => outputHost.querySelector(`[data-output-idx="${idx}"]`).remove(); }
    document.getElementById('addInput').onclick = () => addInput();
    document.getElementById('addOutput').onclick = () => addOutput();

    if (existing && existing.inputs.length) existing.inputs.forEach(i => addInput({ itemId: i.itemId, quantity: i.quantity })); else addInput();
    if (existing && existing.outputs.length) existing.outputs.forEach(o => addOutput({ itemId: o.itemId, quantity: o.quantity })); else addOutput();

    document.getElementById('saveProd').onclick = async (e) => {
      const inputs = []; inputHost.querySelectorAll('[data-input-idx]').forEach(row => { const itemId = row.querySelector('.p-input-item').value; const qty = Number(row.querySelector('.p-input-qty').value || 0); if (itemId && qty > 0) inputs.push({ itemId, quantity: qty }); });
      const outputs = []; outputHost.querySelectorAll('[data-output-idx]').forEach(row => { const itemId = row.querySelector('.p-output-item').value; const qty = Number(row.querySelector('.p-output-qty').value || 0); if (itemId && qty > 0) outputs.push({ itemId, quantity: qty }); });
      if (!inputs.length || !outputs.length) { toast('Add at least one input and one output.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try {
        const payload = { date: document.getElementById('pDate').value, notes: document.getElementById('pNotes').value, inputs, outputs };
        if (mode === 'edit') { await Api.call('updateProduction', { productionId: existingProductionId, payload }); toast('Production entry updated.'); navigate('#/production/' + existingProductionId); }
        else { const res = await Api.call('createProduction', { payload }); toast('Production entry saved.'); navigate('#/production/' + res.productionId); }
      } catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = mode === 'edit' ? 'Save changes' : 'Save production entry'; }
    };
  }

  function screenNewProduction() { return renderProductionForm('new'); }
  function screenEditProduction(productionId) { return renderProductionForm('edit', productionId); }

  // ---------- INVENTORY ----------

  async function screenInventory() {
    shell('Inventory', `<div class="panel" id="stockList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more' });
    try {
      const stock = await Api.call('getCurrentStock');
      document.getElementById('stockList').innerHTML = stock.length ? stock.map(s => `
        <div class="list-row" data-go="#/inventory/${esc(s.itemId)}"><div><div class="row-title">${esc(s.name)}${!s.active ? ' <span class="muted">(inactive)</span>' : ''}</div><div class="row-sub">${esc(s.type)}</div></div><div class="amount ${s.currentStock <= 0 ? 'red' : ''}">${s.currentStock} ${esc(s.unit)}</div></div>`).join('') : '<div class="empty-state"><div class="empty-title">No items yet</div><p>Add products first under More &rsaquo; Admin &rsaquo; Products.</p></div>';
      bindGoAttrs();
    } catch (e) { document.getElementById('stockList').innerHTML = errorState(e.message); }
  }

  async function screenInventoryItem(itemId) {
    shell('Stock history', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    try {
      const [items, movements] = await Promise.all([ensureItems(), Api.call('getStockMovementHistory', { itemId })]);
      const item = items.find(i => i.ItemId === itemId) || { Name: itemId };
      document.querySelector('.top-bar h1').textContent = item.Name;
      const user = Api.getUser();
      const isAdmin = user && user.role === 'Admin';
      document.querySelector('.screen').innerHTML = `
        ${isAdmin ? `<button class="btn btn-secondary btn-sm" data-go="#/inventory/${esc(itemId)}/adjust">Adjust stock</button><div class="divider"></div>` : ''}
        <div class="panel">${movements.length ? movements.map(m => `
          <div class="list-row">
            <div><div class="row-title">${esc(m.MovementType)}</div><div class="row-sub">${fmtDate(m.Date)}${m.Notes ? ' · ' + esc(m.Notes) : ''}</div></div>
            <div style="display:flex;align-items:center;gap:8px;">
              <div class="amount ${Number(m.Quantity) < 0 ? 'red' : 'green'}">${Number(m.Quantity) > 0 ? '+' : ''}${m.Quantity} ${esc(m.Unit)}</div>
              ${isAdmin && m.MovementType === 'StockAdjustment' && !m.Notes.toString().startsWith('Reversal') ? `<button class="li-remove" data-reverse="${esc(m.MovementId)}">Undo</button>` : ''}
            </div>
          </div>`).join('') : '<div class="empty-state">No movements recorded yet.</div>'}</div>
      `;
      bindGoAttrs();
      document.querySelectorAll('[data-reverse]').forEach(btn => btn.onclick = async () => {
        if (!confirmAction('Reverse this stock adjustment with an offsetting entry?')) return;
        try { await Api.call('reverseStockAdjustment', { movementId: btn.dataset.reverse, reason: '' }); toast('Reversed.'); screenInventoryItem(itemId); }
        catch (err) { toast(err.message); }
      });
    } catch (e) { document.querySelector('.screen').innerHTML = errorState(e.message); }
  }

  async function screenAdjustStock(itemId) {
    shell('Adjust stock', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await ensureItems();
    const item = items.find(i => i.ItemId === itemId) || { Name: itemId, Unit: '' };
    document.querySelector('.screen').innerHTML = `
      <p class="muted">Adjusting <strong>${esc(item.Name)}</strong>. Use a positive number to add stock, negative to remove.</p>
      <div class="field"><label>Quantity (${esc(item.Unit)})</label><input type="number" step="0.01" id="adjQty"></div>
      <div class="field"><label>Reason</label><textarea id="adjReason" rows="2" placeholder="e.g. Physical count correction"></textarea></div>
      <button class="btn btn-primary" id="saveAdj">Save adjustment</button>
    `;
    document.getElementById('saveAdj').onclick = async (e) => {
      const qty = Number(document.getElementById('adjQty').value || 0);
      const reason = document.getElementById('adjReason').value.trim();
      if (!qty) { toast('Enter a non-zero quantity.'); return; }
      if (!reason) { toast('A reason is required.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('createStockAdjustment', { itemId, quantity: qty, reason }); toast('Stock adjusted.'); navigate('#/inventory/' + itemId); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Save adjustment'; }
    };
  }

  // ---------- ADMIN: PRODUCTS ----------

  async function screenAdminProducts() {
    shell('Products', `<div class="panel" id="prodItemList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more', actionLabel: '+ New', onAction: () => navigate('#/admin/products/new') });
    try {
      const items = await Api.call('listItems', { includeInactive: true });
      document.getElementById('prodItemList').innerHTML = items.length ? items.map(i => `
        <div class="list-row">
          <div><div class="row-title">${esc(i.Name)}${i.Active === false ? ' <span class="muted">(inactive)</span>' : ''}</div><div class="row-sub">${esc(i.Type)} · ${esc(i.Unit)}${Number(i.TaxRate) > 0 ? ' · ' + i.TaxRate + '% tax' : ''}</div></div>
          <div style="display:flex;gap:10px;">
            <button class="li-remove" style="color:var(--navy-700)" data-edit-item="${esc(i.ItemId)}">Edit</button>
            <button class="li-remove" data-toggle-item="${esc(i.ItemId)}" data-active="${i.Active !== false}">${i.Active === false ? 'Reactivate' : 'Deactivate'}</button>
          </div>
        </div>`).join('') : '<div class="empty-state">No products yet.</div>';
      document.querySelectorAll('[data-edit-item]').forEach(btn => btn.onclick = () => navigate('#/admin/products/' + btn.dataset.editItem + '/edit'));
      document.querySelectorAll('[data-toggle-item]').forEach(btn => btn.onclick = async () => {
        const currentlyActive = btn.dataset.active === 'true';
        try { await Api.call('setItemActive', { itemId: btn.dataset.toggleItem, active: !currentlyActive }); State.items = null; toast(currentlyActive ? 'Product deactivated.' : 'Product reactivated.'); screenAdminProducts(); }
        catch (err) { toast(err.message); }
      });
    } catch (e) { document.getElementById('prodItemList').innerHTML = errorState(e.message); }
  }

  function screenNewProduct() {
    shell('New product', `
      <div class="field"><label>Name</label><input id="itemName" placeholder="e.g. Groundnut Oil"></div>
      <div class="field"><label>Type</label><select id="itemType"><option value="RawMaterial">Raw material</option><option value="FinishedOil">Finished oil</option><option value="CakeByProduct">Cake by-product</option></select></div>
      <div class="field"><label>Unit</label><select id="itemUnit"><option value="L">Litres (L)</option><option value="Kg">Kilograms (Kg)</option></select></div>
      <div class="field"><label>Tax rate % (used only when GST is enabled)</label><input type="number" min="0" step="0.01" id="itemTax" value="0"></div>
      <button class="btn btn-primary" id="saveItem">Save product</button>
    `, { activeTab: 'more' });
    document.getElementById('saveItem').onclick = async (e) => {
      const name = document.getElementById('itemName').value.trim();
      if (!name) { toast('Enter a product name.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('createItem', { item: { name, type: document.getElementById('itemType').value, unit: document.getElementById('itemUnit').value, taxRate: Number(document.getElementById('itemTax').value || 0) } }); State.items = null; toast('Product added.'); navigate('#/admin/products'); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Save product'; }
    };
  }

  async function screenEditProduct(itemId) {
    shell('Edit product', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await Api.call('listItems', { includeInactive: true });
    const item = items.find(i => i.ItemId === itemId);
    if (!item) { document.querySelector('.screen').innerHTML = errorState('Product not found.'); return; }
    document.querySelector('.screen').innerHTML = `
      <div class="field"><label>Name</label><input id="itemName" value="${esc(item.Name)}"></div>
      <div class="field"><label>Type</label><select id="itemType"><option value="RawMaterial" ${item.Type === 'RawMaterial' ? 'selected' : ''}>Raw material</option><option value="FinishedOil" ${item.Type === 'FinishedOil' ? 'selected' : ''}>Finished oil</option><option value="CakeByProduct" ${item.Type === 'CakeByProduct' ? 'selected' : ''}>Cake by-product</option></select></div>
      <div class="field"><label>Unit</label><select id="itemUnit"><option value="L" ${item.Unit === 'L' ? 'selected' : ''}>Litres (L)</option><option value="Kg" ${item.Unit === 'Kg' ? 'selected' : ''}>Kilograms (Kg)</option></select></div>
      <div class="field"><label>Tax rate %</label><input type="number" min="0" step="0.01" id="itemTax" value="${Number(item.TaxRate || 0)}"></div>
      <button class="btn btn-primary" id="saveItem">Save changes</button>
    `;
    document.getElementById('saveItem').onclick = async (e) => {
      const name = document.getElementById('itemName').value.trim();
      if (!name) { toast('Enter a product name.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('updateItem', { itemId, updates: { name, type: document.getElementById('itemType').value, unit: document.getElementById('itemUnit').value, taxRate: Number(document.getElementById('itemTax').value || 0) } }); State.items = null; toast('Product updated.'); navigate('#/admin/products'); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Save changes'; }
    };
  }

  // ---------- ADMIN: PRICE BOOK ----------

  async function screenAdminPrices() {
    shell('Price book', `<div class="panel" id="priceItemList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more' });
    try {
      const current = await Api.call('getCurrentPrices');
      document.getElementById('priceItemList').innerHTML = current.length ? current.map(i => `
        <div class="list-row" data-go="#/admin/prices/${esc(i.itemId)}">
          <div><div class="row-title">${esc(i.name)}</div><div class="row-sub">${i.effectiveFrom ? 'as of ' + fmtDate(i.effectiveFrom) : 'no price set'}</div></div>
          <div class="amount ${i.currentPrice === null ? 'red' : ''}">${i.currentPrice === null ? '—' : money(i.currentPrice)}</div>
        </div>`).join('') : '<div class="empty-state">Add products first.</div>';
      bindGoAttrs();
    } catch (e) { document.getElementById('priceItemList').innerHTML = errorState(e.message); }
  }

  async function screenAdminPriceItem(itemId) {
    shell('Prices', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await ensureItems();
    const item = items.find(i => i.ItemId === itemId) || { Name: itemId };
    document.querySelector('.top-bar h1').textContent = item.Name;
    const rows = await Api.call('listPrices', { itemId });
    document.querySelector('.screen').innerHTML = `
      <div class="field"><label>New effective date</label><input type="date" id="newPriceDate" value="${todayInputValue()}"></div>
      <div class="field"><label>Price per ${esc(item.Unit || 'unit')}</label><input type="number" min="0" step="0.01" id="newPriceValue"></div>
      <button class="btn btn-primary" id="savePrice">Add price</button>
      <div class="section-label">History</div>
      <div class="panel" id="priceHistList">${rows.length ? rows.map(r => priceHistRow(r)).join('') : '<div class="empty-state">No prices set yet.</div>'}</div>
    `;
    bindPriceHistEvents(itemId);
    document.getElementById('savePrice').onclick = async (e) => {
      const price = Number(document.getElementById('newPriceValue').value || 0);
      if (!(price > 0)) { toast('Enter a price greater than zero.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('addPrice', { itemId, effectiveFrom: document.getElementById('newPriceDate').value, price }); delete State.priceCache[itemId]; toast('Price added.'); screenAdminPriceItem(itemId); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Add price'; }
    };
  }

  function priceHistRow(r) {
    return `<div class="list-row" data-price-row="${esc(r.PriceId)}">
      <div class="row-title" data-display>${fmtDate(r.EffectiveFrom)}</div>
      <div style="display:flex;align-items:center;gap:10px;">
        <div class="amount" data-display>${money(r.Price)}</div>
        <button class="li-remove" style="color:var(--navy-700)" data-edit-price="${esc(r.PriceId)}">Edit</button>
        <button class="li-remove" data-delete-price="${esc(r.PriceId)}">Delete</button>
      </div>
    </div>`;
  }

  function bindPriceHistEvents(itemId) {
    document.querySelectorAll('[data-edit-price]').forEach(btn => btn.onclick = () => {
      const row = document.querySelector(`[data-price-row="${btn.dataset.editPrice}"]`);
      const dateText = row.querySelector('[data-display].row-title').textContent;
      const amtText = row.querySelector('[data-display].amount').textContent.replace(/[^0-9.]/g, '');
      row.innerHTML = `
        <input type="date" class="edit-price-date" style="flex:1;margin-right:8px;padding:8px;border:1px solid var(--line);border-radius:6px;">
        <input type="number" step="0.01" class="edit-price-amt" value="${esc(amtText)}" style="width:100px;padding:8px;border:1px solid var(--line);border-radius:6px;margin-right:8px;">
        <button class="li-remove" style="color:var(--green-700)" data-save-price="${btn.dataset.editPrice}">Save</button>`;
    });
    document.querySelectorAll('[data-delete-price]').forEach(btn => btn.onclick = async () => {
      if (!confirmAction('Delete this price entry?')) return;
      try { await Api.call('deletePrice', { priceId: btn.dataset.deletePrice }); delete State.priceCache[itemId]; toast('Deleted.'); screenAdminPriceItem(itemId); }
      catch (err) { toast(err.message); }
    });
    document.body.addEventListener('click', async function saveHandler(ev) {
      const btn = ev.target.closest('[data-save-price]');
      if (!btn) return;
      const row = btn.closest('[data-price-row]');
      const date = row.querySelector('.edit-price-date').value;
      const amt = Number(row.querySelector('.edit-price-amt').value || 0);
      if (!date || !(amt > 0)) { toast('Enter a valid date and price.'); return; }
      try { await Api.call('updatePrice', { priceId: btn.dataset.savePrice, effectiveFrom: date, price: amt }); delete State.priceCache[itemId]; toast('Updated.'); screenAdminPriceItem(itemId); }
      catch (err) { toast(err.message); }
    }, { once: true });
  }

  // ---------- ADMIN: BOTTLE ADJUSTMENTS ----------

  async function screenAdminBottle() {
    shell('Bottle adjustments', `<div class="panel" id="bottleItemList"><div class="empty-state">Loading…</div></div>`, { activeTab: 'more' });
    try {
      const current = await Api.call('getCurrentBottleAdjustments');
      document.getElementById('bottleItemList').innerHTML = current.length ? current.map(i => `
        <div class="list-row" data-go="#/admin/bottle/${esc(i.itemId)}">
          <div><div class="row-title">${esc(i.name)}</div><div class="row-sub">${i.effectiveFrom ? 'as of ' + fmtDate(i.effectiveFrom) : 'none set'}</div></div>
          <div class="amount">${i.currentAmount === null ? '—' : money(i.currentAmount)}</div>
        </div>`).join('') : '<div class="empty-state">Add products first.</div>';
      bindGoAttrs();
    } catch (e) { document.getElementById('bottleItemList').innerHTML = errorState(e.message); }
  }

  async function screenAdminBottleItem(itemId) {
    shell('Bottle adjustment', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const items = await ensureItems();
    const item = items.find(i => i.ItemId === itemId) || { Name: itemId };
    document.querySelector('.top-bar h1').textContent = item.Name;
    const rows = await Api.call('listBottleAdjustments', { itemId });
    document.querySelector('.screen').innerHTML = `
      <p class="muted">Amount deducted per ${esc(item.Unit || 'unit')} when the customer supplies their own bottle.</p>
      <div class="field"><label>New effective date</label><input type="date" id="newAdjDate" value="${todayInputValue()}"></div>
      <div class="field"><label>Deduction amount</label><input type="number" min="0" step="0.01" id="newAdjValue"></div>
      <button class="btn btn-primary" id="saveAdj">Add adjustment</button>
      <div class="section-label">History</div>
      <div class="panel" id="adjHistList">${rows.length ? rows.map(r => bottleHistRow(r)).join('') : '<div class="empty-state">No adjustments set yet.</div>'}</div>
    `;
    bindBottleHistEvents(itemId);
    document.getElementById('saveAdj').onclick = async (e) => {
      const amount = Number(document.getElementById('newAdjValue').value || 0);
      if (!(amount >= 0)) { toast('Enter a valid amount.'); return; }
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('addBottleAdjustment', { itemId, effectiveFrom: document.getElementById('newAdjDate').value, amount }); delete State.adjCache[itemId]; toast('Adjustment added.'); screenAdminBottleItem(itemId); }
      catch (err) { toast(err.message); e.target.disabled = false; e.target.textContent = 'Add adjustment'; }
    };
  }

  function bottleHistRow(r) {
    return `<div class="list-row" data-adj-row="${esc(r.AdjustmentId)}">
      <div class="row-title" data-display>${fmtDate(r.EffectiveFrom)}</div>
      <div style="display:flex;align-items:center;gap:10px;">
        <div class="amount" data-display>${money(r.Amount)}</div>
        <button class="li-remove" style="color:var(--navy-700)" data-edit-adj="${esc(r.AdjustmentId)}">Edit</button>
        <button class="li-remove" data-delete-adj="${esc(r.AdjustmentId)}">Delete</button>
      </div>
    </div>`;
  }

  function bindBottleHistEvents(itemId) {
    document.querySelectorAll('[data-edit-adj]').forEach(btn => btn.onclick = () => {
      const row = document.querySelector(`[data-adj-row="${btn.dataset.editAdj}"]`);
      const amtText = row.querySelector('[data-display].amount').textContent.replace(/[^0-9.]/g, '');
      row.innerHTML = `
        <input type="date" class="edit-adj-date" style="flex:1;margin-right:8px;padding:8px;border:1px solid var(--line);border-radius:6px;">
        <input type="number" step="0.01" class="edit-adj-amt" value="${esc(amtText)}" style="width:100px;padding:8px;border:1px solid var(--line);border-radius:6px;margin-right:8px;">
        <button class="li-remove" style="color:var(--green-700)" data-save-adj="${btn.dataset.editAdj}">Save</button>`;
    });
    document.querySelectorAll('[data-delete-adj]').forEach(btn => btn.onclick = async () => {
      if (!confirmAction('Delete this adjustment entry?')) return;
      try { await Api.call('deleteBottleAdjustment', { adjustmentId: btn.dataset.deleteAdj }); delete State.adjCache[itemId]; toast('Deleted.'); screenAdminBottleItem(itemId); }
      catch (err) { toast(err.message); }
    });
    document.body.addEventListener('click', async function saveHandler(ev) {
      const btn = ev.target.closest('[data-save-adj]');
      if (!btn) return;
      const row = btn.closest('[data-adj-row]');
      const date = row.querySelector('.edit-adj-date').value;
      const amt = Number(row.querySelector('.edit-adj-amt').value || 0);
      if (!date || amt < 0) { toast('Enter a valid date and amount.'); return; }
      try { await Api.call('updateBottleAdjustment', { adjustmentId: btn.dataset.saveAdj, effectiveFrom: date, amount: amt }); delete State.adjCache[itemId]; toast('Updated.'); screenAdminBottleItem(itemId); }
      catch (err) { toast(err.message); }
    }, { once: true });
  }

  // ---------- ADMIN: SETTINGS ----------

  async function screenAdminSettings() {
    shell('Business settings', `<div class="empty-state">Loading…</div>`, { activeTab: 'more' });
    const s = await Api.call('getSettings');
    document.querySelector('.screen').innerHTML = `
      <div class="field"><label>Company name</label><input id="setName" value="${esc(s.companyName || '')}"></div>
      <div class="field"><label>Motto</label><input id="setMotto" value="${esc(s.motto || '')}"></div>
      <div class="checkbox-row" style="margin-bottom:14px;"><input type="checkbox" id="setGst" ${s.gstEnabled === 'true' || s.gstEnabled === true ? 'checked' : ''}><label for="setGst">GST enabled</label></div>
      <div class="field"><label>Logo URL (optional)</label><input id="setLogo" value="${esc(s.logoUrl || '')}"></div>
      <button class="btn btn-primary" id="saveSettings">Save settings</button>
    `;
    document.getElementById('saveSettings').onclick = async (e) => {
      e.target.disabled = true; e.target.textContent = 'Saving…';
      try { await Api.call('updateSettings', { updates: { companyName: document.getElementById('setName').value, motto: document.getElementById('setMotto').value, gstEnabled: document.getElementById('setGst').checked ? 'true' : 'false', logoUrl: document.getElementById('setLogo').value } }); toast('Settings saved.'); }
      catch (err) { toast(err.message); }
      e.target.disabled = false; e.target.textContent = 'Save settings';
    };
  }

  // ---------- ROUTER ----------

  function parseQuery(str) {
    const out = {};
    if (!str) return out;
    str.split('&').forEach(pair => { const [k, v] = pair.split('='); if (k) out[decodeURIComponent(k)] = decodeURIComponent(v || ''); });
    return out;
  }

  async function route() {
    const hasToken = !!Api.getToken();
    const raw = (location.hash || '#/dashboard').slice(1);
    const [path, queryStr] = raw.split('?');
    const segments = path.split('/').filter(Boolean);
    const query = parseQuery(queryStr);

    if (!hasToken) { screenLogin(); return; }
    if (segments[0] === 'login') { navigate('#/dashboard'); return; }

    try {
      if (segments.length === 0 || segments[0] === 'dashboard') return screenDashboard();
      if (segments[0] === 'more') return screenMore();
      if (segments[0] === 'customers') {
        if (segments.length === 1) return screenCustomers();
        if (segments[1] === 'new') return screenNewCustomer();
        if (segments.length === 3 && segments[2] === 'pay') return screenRecordPayment(segments[1], query.sale);
        return screenCustomerDetail(segments[1]);
      }
      if (segments[0] === 'payments' && segments[1] === 'new') return screenRecordPayment(query.customer, query.sale);
      if (segments[0] === 'sales') {
        if (segments.length === 1) return screenSales();
        if (segments[1] === 'new') return screenNewSale(query.customer);
        if (segments.length === 3 && segments[2] === 'edit') return screenEditSale(segments[1]);
        return screenSaleDetail(segments[1]);
      }
      if (segments[0] === 'quotations') {
        if (segments.length === 1) return screenQuotations();
        if (segments[1] === 'new') return screenNewQuotation();
        if (segments.length === 3 && segments[2] === 'convert') return screenConvertQuotation(segments[1]);
        if (segments.length === 3 && segments[2] === 'edit') return screenEditQuotation(segments[1]);
        return screenQuotationDetail(segments[1]);
      }
      if (segments[0] === 'production') {
        if (segments.length === 1) return screenProduction();
        if (segments[1] === 'new') return screenNewProduction();
        if (segments.length === 3 && segments[2] === 'edit') return screenEditProduction(segments[1]);
        return screenProductionDetail(segments[1]);
      }
      if (segments[0] === 'inventory') {
        if (segments.length === 1) return screenInventory();
        if (segments.length === 3 && segments[2] === 'adjust') return screenAdjustStock(segments[1]);
        return screenInventoryItem(segments[1]);
      }
      if (segments[0] === 'admin') {
        if (segments[1] === 'products') {
          if (segments[2] === 'new') return screenNewProduct();
          if (segments.length === 4 && segments[3] === 'edit') return screenEditProduct(segments[2]);
          return screenAdminProducts();
        }
        if (segments[1] === 'prices') { if (segments.length === 3) return screenAdminPriceItem(segments[2]); return screenAdminPrices(); }
        if (segments[1] === 'bottle') { if (segments.length === 3) return screenAdminBottleItem(segments[2]); return screenAdminBottle(); }
        if (segments[1] === 'settings') return screenAdminSettings();
      }
      return screenDashboard();
    } catch (e) { toast(e.message || 'Something went wrong.'); }
  }

  function init() { window.addEventListener('hashchange', route); route(); }
  return { init };
})();

document.addEventListener('DOMContentLoaded', App.init);
