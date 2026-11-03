-- ════════════════════════════════════════════════════════════════════
--  MIGRACIÓN: MODALIDAD Y FILTRO DE UBICACIÓN
--  Ejecutar en Supabase SQL Editor
-- ════════════════════════════════════════════════════════════════════

-- 1. Agregar columnas a la tabla de lotes (sin alterar datos existentes)
alter table lots
  add column if not exists modality text not null default 'digital'
    check (modality in ('digital', 'presencial', 'envio')),
  add column if not exists location_province text,
  add column if not exists location_city text,
  add column if not exists shipping_notes text;

-- 2. Índices para acelerar búsquedas y filtros
create index if not exists lots_modality_idx on lots (modality);
create index if not exists lots_province_idx on lots (location_province);

-- 3. Documentación / Comentarios de las columnas
comment on column lots.modality is 'Modalidad de entrega: digital (online/a distancia), presencial (retiro en persona o servicio presencial), o envio (con despacho por encomienda)';
comment on column lots.location_province is 'Provincia argentina donde se retira o se presta el servicio presencial';
comment on column lots.location_city is 'Localidad, barrio o zona específica del servicio o retiro';
comment on column lots.shipping_notes is 'Aclaración de entrega o retiro acordado';

