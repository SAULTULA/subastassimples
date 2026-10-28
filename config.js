// Clave "publishable": es pública por diseño. La seguridad la dan las políticas RLS de schema.sql
window.SB = supabase.createClient(
  'https://voxzuzzltjifasouacbq.supabase.co',
  'sb_publishable_5IwZPnpgMbZyeOeOOBmZ-w_qvCxHMx1'
);
window.$ = id => document.getElementById(id);
window.esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
window.money = n => '$' + Number(n || 0).toLocaleString('es-AR');
