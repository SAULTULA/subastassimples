// POST /api/create-payment   { lot_id, participant_id, secret }
// El monto sale de la oferta ganadora guardada en Supabase, nunca del navegador.
const { rpc } = require('../lib/supabase');

module.exports = async (req, res) => {
  if (req.method !== 'POST') return res.status(405).json({ error: 'Método no permitido' });

  const token = process.env.MP_ACCESS_TOKEN;
  const siteUrl = (process.env.SITE_URL || '').replace(/\/$/, '');
  if (!token || !siteUrl || !process.env.SUPABASE_URL || !process.env.SUPABASE_SECRET_KEY) {
    return res.status(500).json({ error: 'Faltan variables de entorno en Vercel' });
  }

  const { lot_id, participant_id, secret } = req.body || {};
  if (!lot_id || !participant_id || !secret) {
    return res.status(400).json({ error: 'Datos incompletos' });
  }

  try {
    // Verifica: lote cerrado + es el ganador + llave correcta + todavía sin pagar
    const info = await rpc('get_payment_info', {
      p_lot: String(lot_id),
      p_participant: String(participant_id),
      p_secret: String(secret)
    });
    if (!info) {
      return res.status(403).json({ error: 'Este lote no se puede pagar (no sos el ganador o ya está pago).' });
    }

    const preference = {
      items: [{
        title: String(info.title).slice(0, 120),
        quantity: 1,
        unit_price: Number(info.amount),
        currency_id: 'ARS'
      }],
      external_reference: String(lot_id),
      back_urls: {
        success: `${siteUrl}/?pago=ok`,
        pending: `${siteUrl}/?pago=pendiente`,
        failure: `${siteUrl}/?pago=error`
      },
      auto_return: 'approved'
    };

    const r = await fetch('https://api.mercadopago.com/checkout/preferences', {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(preference)
    });
    const data = await r.json();
    if (!r.ok) {
      console.error('MP rechazó la preferencia:', data);
      return res.status(502).json({ error: 'Mercado Pago rechazó la solicitud' });
    }
    return res.status(200).json({ url: data.init_point });
  } catch (err) {
    console.error(err);
    return res.status(500).json({ error: 'No se pudo iniciar el pago' });
  }
};
