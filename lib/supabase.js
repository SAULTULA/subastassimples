// Llama a una función SQL de Supabase usando la clave SECRETA (solo en el servidor).
// Las claves nuevas (sb_secret_...) van únicamente en el header "apikey".
async function rpc(fn, args) {
  const r = await fetch(`${process.env.SUPABASE_URL}/rest/v1/rpc/${fn}`, {
    method: 'POST',
    headers: {
      apikey: process.env.SUPABASE_SECRET_KEY,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(args)
  });
  const text = await r.text();
  if (!r.ok) throw new Error(`Supabase ${fn} ${r.status}: ${text}`);
  return text ? JSON.parse(text) : null;
}

module.exports = { rpc };
