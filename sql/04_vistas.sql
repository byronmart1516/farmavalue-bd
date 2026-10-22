-- ============================================================================
-- FARMAVALUE - 04_vistas.sql (Rol A: reportes)
-- Requiere: 01_ddl.sql (las vistas de ventas muestran datos después de 03_poblado.sql)
-- Se puede volver a ejecutar las veces que se quiera (CREATE OR REPLACE).
-- ============================================================================

SET search_path TO farmavalue;

-- ----------------------------------------------------------------------------
-- RF-04 / Entregable 3: alertas de vencimiento a 30, 60 y 90 días por sucursal
-- ----------------------------------------------------------------------------
CREATE OR REPLACE VIEW v_vencimientos AS
SELECT s.nombre                              AS sucursal,
       p.codigo,
       p.nombre                              AS producto,
       l.numero_lote,
       l.fecha_vencimiento,
       l.fecha_vencimiento - CURRENT_DATE    AS dias_para_vencer,
       CASE
         WHEN l.fecha_vencimiento - CURRENT_DATE <= 30 THEN '0-30 días'
         WHEN l.fecha_vencimiento - CURRENT_DATE <= 60 THEN '31-60 días'
         ELSE '61-90 días'
       END                                   AS rango_alerta,
       il.existencia,
       il.existencia * p.precio_venta        AS valor_en_riesgo,
       EXISTS (SELECT 1 FROM promocion po
               WHERE po.id_lote = l.id_lote AND po.activa
                 AND CURRENT_DATE BETWEEN po.fecha_inicio AND po.fecha_fin)
                                             AS tiene_promocion
FROM inventario_lote il
JOIN lote     l ON l.id_lote     = il.id_lote
JOIN producto p ON p.id_producto = l.id_producto
JOIN sucursal s ON s.id_sucursal = il.id_sucursal
WHERE l.fecha_vencimiento BETWEEN CURRENT_DATE AND CURRENT_DATE + 90
  AND il.existencia > 0;

-- Resumen por sucursal y rango (para el informe y el prototipo)
CREATE OR REPLACE VIEW v_vencimientos_resumen AS
SELECT sucursal,
       rango_alerta,
       count(*)             AS lotes,
       sum(existencia)      AS unidades,
       sum(valor_en_riesgo) AS valor_en_riesgo
FROM v_vencimientos
GROUP BY sucursal, rango_alerta
ORDER BY sucursal, rango_alerta;

-- ----------------------------------------------------------------------------
-- Reportes de ventas y métricas (Entregable 6)
-- ----------------------------------------------------------------------------
-- Ventas por sucursal y mes
CREATE OR REPLACE VIEW v_ventas_sucursal AS
SELECT s.nombre                               AS sucursal,
       date_trunc('month', pe.fecha)::date    AS mes,
       count(*)                               AS pedidos,
       sum(pa.monto_bruto)                    AS venta_bruta,
       sum(pa.descuento_seguro)               AS cubierto_por_seguro,
       sum(pa.descuento_puntos)               AS canjeado_en_puntos,
       sum(pa.comision)                       AS comisiones,
       sum(pa.monto_neto)                     AS neto_depositado
FROM pedido pe
JOIN pago     pa ON pa.id_pedido  = pe.id_pedido
JOIN sucursal s  ON s.id_sucursal = pe.id_sucursal
WHERE pe.estado <> 'ANULADO'
GROUP BY s.nombre, date_trunc('month', pe.fecha)
ORDER BY sucursal, mes;

-- Ventas por canal (App, POS, Call Center)
CREATE OR REPLACE VIEW v_ventas_canal AS
SELECT pe.canal,
       count(*)                                 AS pedidos,
       sum(pa.monto_bruto)                      AS venta_bruta,
       round(avg(pa.monto_bruto), 2)            AS ticket_promedio
FROM pedido pe
JOIN pago pa ON pa.id_pedido = pe.id_pedido
WHERE pe.estado <> 'ANULADO'
GROUP BY pe.canal
ORDER BY venta_bruta DESC;

-- Productos más vendidos (unidades e ingresos ya con descuento de promoción)
CREATE OR REPLACE VIEW v_top_productos AS
SELECT p.codigo,
       p.nombre,
       sum(d.cantidad)                                          AS unidades,
       sum(d.cantidad * (d.precio_unitario - d.descuento_unitario)) AS ingresos
FROM detalle_pedido d
JOIN pedido   pe ON pe.id_pedido  = d.id_pedido
JOIN lote     l  ON l.id_lote     = d.id_lote
JOIN producto p  ON p.id_producto = l.id_producto
WHERE pe.estado <> 'ANULADO'
GROUP BY p.codigo, p.nombre
ORDER BY unidades DESC;

-- RF-05: conciliación financiera por pasarela, al centavo
CREATE OR REPLACE VIEW v_conciliacion_pasarela AS
SELECT ps.nombre                                         AS pasarela,
       ps.comision_pct,
       count(*)                                          AS pagos,
       sum(pa.monto_bruto)                               AS venta_bruta,
       sum(pa.descuento_seguro)                          AS cubierto_por_seguro,
       sum(pa.descuento_puntos)                          AS canjeado_en_puntos,
       sum(pa.monto_bruto - pa.descuento_seguro - pa.descuento_puntos) AS cobrado_al_cliente,
       sum(pa.comision)                                  AS comisiones,
       sum(pa.monto_neto)                                AS neto_depositado
FROM pago pa
JOIN pasarela ps ON ps.id_pasarela = pa.id_pasarela
GROUP BY ps.nombre, ps.comision_pct
ORDER BY venta_bruta DESC;

-- Kardex por lote y sucursal: saldo calculado vs existencia real (trazabilidad)
CREATE OR REPLACE VIEW v_kardex_saldo AS
SELECT s.nombre                       AS sucursal,
       l.numero_lote,
       p.codigo,
       sum(m.cantidad) FILTER (WHERE m.cantidad > 0)  AS entradas,
       -sum(m.cantidad) FILTER (WHERE m.cantidad < 0) AS salidas,
       sum(m.cantidad)                AS saldo_kardex,
       il.existencia                  AS existencia_actual,
       sum(m.cantidad) = il.existencia AS cuadra
FROM movimiento_inventario m
JOIN inventario_lote il ON il.id_lote = m.id_lote AND il.id_sucursal = m.id_sucursal
JOIN lote     l ON l.id_lote     = m.id_lote
JOIN producto p ON p.id_producto = l.id_producto
JOIN sucursal s ON s.id_sucursal = m.id_sucursal
GROUP BY s.nombre, l.numero_lote, p.codigo, il.existencia;

-- Historial de precios: sale de la auditoría, sin tabla nueva.
-- trg_aud_producto guarda la fila completa antes y después de cada cambio en producto;
-- esta vista se queda solo con los cambios de precio_venta.
CREATE OR REPLACE VIEW v_historial_precios AS
SELECT p.codigo,
       p.nombre                                          AS producto,
       (a.valor_anterior ->> 'precio_venta')::numeric    AS precio_anterior,
       (a.valor_nuevo    ->> 'precio_venta')::numeric    AS precio_nuevo,
       round(((a.valor_nuevo ->> 'precio_venta')::numeric
              - (a.valor_anterior ->> 'precio_venta')::numeric)
             / (a.valor_anterior ->> 'precio_venta')::numeric * 100, 2) AS variacion_pct,
       a.usuario,
       a.fecha                                           AS fecha_cambio
FROM auditoria a
JOIN producto p ON p.id_producto = (a.valor_nuevo ->> 'id_producto')::int
WHERE a.tabla_afectada = 'producto'
  AND a.operacion = 'UPDATE'
  AND a.valor_anterior ->> 'precio_venta' IS DISTINCT FROM a.valor_nuevo ->> 'precio_venta';
