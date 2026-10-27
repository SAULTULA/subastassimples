// Clave "publishable": es pública por diseño. La seguridad la dan las políticas RLS de schema.sql
window.SB = supabase.createClient(
  'https://amylgusyfmlldwwxmfno.supabase.co',
  'sb_publishable_vKpKhqKl_JbnQoWhHY_dmA_n0QI_k5W'
);
window.ADMIN_WA = '5491166508379'; // 11 6650-8379
window.$ = id => document.getElementById(id);
window.esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
window.money = n => '$' + Number(n || 0).toLocaleString('es-AR');
