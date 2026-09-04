// Replaces the old Apps Script /exec URL — this app now talks to
// Supabase directly. Fill in your Supabase project's URL and anon key
// (Project Settings -> API in the Supabase dashboard). Same anon key
// is safe here as in the storefront: RLS + the SECURITY DEFINER
// functions in supabase/staff/*.sql control what it can actually do,
// not the key itself.
window.SRI_CONFIG = {
  SUPABASE_URL: 'https://vllvtumztjoiuxnktgxp.supabase.co',
  SUPABASE_ANON_KEY: 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InZsbHZ0dW16dGpvaXV4bmt0Z3hwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODg0NzMxNjksImV4cCI6MjEwNDA0OTE2OX0.UzGtmogM3odu4TGPuTngFZFixDA5NhDwi5MzuN9WieE',

  // Staff log in with a short username (matching the old Sheets-based
  // login screen), not a full email address — Supabase Auth requires
  // an email under the hood, so a username like "priya" becomes
  // "priya@<this domain>" internally. Staff never see or type this;
  // it only matters when you create their account (see
  // supabase/staff/README.md).
  STAFF_EMAIL_DOMAIN: 'staff.sriproducts.local'
};
