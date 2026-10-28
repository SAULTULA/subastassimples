// POST /api/mp-webhook  (Mercado Pago avisa acá cuando hay un pago)
// 1) valida la firma  2) consulta el pago real  3) marca el lote como pagado  4) te avisa por Telegram
const crypto = require('crypto');
const { rpc } = require('../lib/supabase');

function firmaValida(req, dataId) {
  const secret = process.env.MP_WEBHOOK_SECRET;
  const xSignature = req.headers['x-signature'];
  const xRequestId = req.headers['x-request-id'];
  if (!secret || !xSignature) return false;

  let ts, v1;
  xSignature.split(',').forEach((part) => {
    const [k, v] = part.split('=').map((s) => s.trim());
    if (k === 'ts') ts = v;
    if (k === 'v1') v1 = v;
  });
  if (!ts || !v1) return false;

  let manifest = '';
  if (dataId) manifest += `id:${String(dataId).toLowerCase()};`;
  if (xRequestId) manifest += `request-id:${xRequestId};`;
  manifest += `ts:${ts};`;

  const esperado = crypto.createHmac('sha256', secret).update(manifest).digest('hex');
  const a = Buffer.from(esperado);
  const b = Buffer.from(v1);
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

async function avisarTelegram(texto) {
  const botToken = process.env.TELEGRAM_BOT_TOKEN;
  const chatId = process.env.TELEGRAM_CHAT_ID;
  if (!botToken || !chatId) return; // opcional
  await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text: texto })
  });
}

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).end();

  const url = new URL(req.url, 'https://placeholder.local');
  const idQuery = url.searchParams.get('data.id');
  const dataId = idQuery || (req.body && req.body.data && req.body.data.id);
  const type = url.searchParams.get('type') || (req.body && req.body.type);

  if (!firmaValida(req, idQuery)) return res.status(401).json({ error: 'Firma inválida' });
  if (type !== 'payment' || !dataId) return res.status(200).json({ ok: true });

  try {
    const r = await fetch(`https://api.mercadopago.com/v1/payments/${dataId}`, {
      headers: { Authorization: `Bearer ${process.env.MP_ACCESS_TOKEN}` }
    });
    if (r.status === 404) return res.status(200).json({ ok: true, ignored: 'pago inexistente' }); // p. ej. notificación de prueba
    if (!r.ok) return res.status(500).json({ error: 'No se pudo consultar el pago' }); // MP reintenta
    const pago = await r.json();

    const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
    if (pago.status === 'approved' && UUID.test(String(pago.external_reference || ''))) {
      const out = await rpc('mark_lot_paid', {
        p_lot: String(pago.external_reference),
        p_payment: String(pago.id),
        p_amount: Number(pago.transaction_amount)
      });

      if (out && out.result === 'paid') {
        await avisarTelegram(
          `✅ ¡Pago recibido!\n${out.title}\nGanó: ${out.winner || '-'}\nMonto: $${out.amount}`
        );
      } else if (out && out.result !== 'already') {
        // Pago aprobado que no coincide con la subasta: hay que revisarlo a mano
        await avisarTelegram(
          `⚠️ Pago aprobado para revisar (${out.result})\nLote: ${pago.external_reference}\n` +
          `Monto: $${pago.transaction_amount}\nID de pago: ${pago.id}`
        );
      }
    }
    return res.status(200).json({ ok: true });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: 'Error procesando el aviso' });
  }
};
