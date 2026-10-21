-- ============================================================================
-- FARMAVALUE - 06_evidencias.sql (Rol A: capturas para el informe)
-- Solo consultas: no cambia nada en la base.
-- Requiere la base completa: 01 -> 02 -> 05 -> 03 -> 04
--
-- CÓMO USARLO: ejecuta UNA consulta a la vez con Ctrl + Enter (cursor dentro
-- de la consulta) y toma la captura del resultado. El nombre sugerido de cada
-- captura va en el comentario; guárdalas en docs/evidencias/.
-- ============================================================================

SET search_path TO farmavalue;

-- a01_conteo_tablas.png  ·  prueba de que todas las tablas tienen datos
SELECT 'sucursal' AS tabla, count(*) AS filas FROM sucursal
UNION ALL SELECT 'categoria',              count(*) FROM categoria
UNION ALL SELECT 'laboratorio',            count(*) FROM laboratorio
UNION ALL SELECT 'producto',               count(*) FROM producto
UNION ALL SELECT 'lote',                   count(*) FROM lote
UNION ALL SELECT 'inventario_lote',        count(*) FROM inventario_lote
UNION ALL SELECT 'aseguradora',            count(*) FROM aseguradora
UNION ALL SELECT 'cliente',                count(*) FROM cliente
UNION ALL SELECT 'empleado',               count(*) FROM empleado
UNION ALL SELECT 'receta',                 count(*) FROM receta
UNION ALL SELECT 'pasarela',               count(*) FROM pasarela
UNION ALL SELECT 'pedido',                 count(*) FROM pedido
UNION ALL SELECT 'promocion',              count(*) FROM promocion
UNION ALL SELECT 'detalle_pedido',         count(*) FROM detalle_pedido
UNION ALL SELECT 'pago',                   count(*) FROM pago
UNION ALL SELECT 'intento_pago',           count(*) FROM intento_pago
UNION ALL SELECT 'reserva',                count(*) FROM reserva
UNION ALL SELECT 'movimiento_puntos',      count(*) FROM movimiento_puntos
UNION ALL SELECT 'movimiento_inventario',  count(*) FROM movimiento_inventario
UNION ALL SELECT 'devolucion_laboratorio', count(*) FROM devolucion_laboratorio
UNION ALL SELECT 'auditoria',              count(*) FROM auditoria;

-- a02_vencimientos_resumen.png  ·  RF-04: lotes por vencer por sucursal y rango
SELECT * FROM v_vencimientos_resumen;

-- a03_vencimientos_zona10.png  ·  detalle de una sucursal, lo más urgente primero
SELECT sucursal, codigo, producto, numero_lote, fecha_vencimiento,
       dias_para_vencer, rango_alerta, existencia, valor_en_riesgo, tiene_promocion
FROM v_vencimientos
WHERE sucursal = 'FarmaValue Zona 10'
ORDER BY dias_para_vencer;

-- a04_ventas_sucursal.png
SELECT * FROM v_ventas_sucursal;

-- a05_ventas_canal.png
SELECT * FROM v_ventas_canal;

-- a06_top_productos.png  ·  los 10 más vendidos
SELECT * FROM v_top_productos LIMIT 10;

-- a07_conciliacion.png  ·  RF-05: bruto - seguro - puntos - comisión = neto
SELECT * FROM v_conciliacion_pasarela;

-- a08_conciliacion_cuadra.png  ·  comprobación al centavo: debe dar 0 pagos con diferencia
SELECT count(*) AS pagos_que_no_cuadran
FROM pago
WHERE monto_bruto - descuento_seguro - descuento_puntos - comision <> monto_neto;

-- a09_kardex_lote.png  ·  problema 2 del caso: historial de un lote (entradas y ventas)
SELECT m.fecha, s.nombre AS sucursal, l.numero_lote, m.tipo, m.cantidad,
       sum(m.cantidad) OVER (PARTITION BY m.id_lote, m.id_sucursal
                             ORDER BY m.fecha, m.id_movimiento) AS saldo,
       m.id_pedido, m.observacion
FROM movimiento_inventario m
JOIN lote l     ON l.id_lote = m.id_lote
JOIN sucursal s ON s.id_sucursal = m.id_sucursal
WHERE m.id_lote = (SELECT id_lote FROM movimiento_inventario
                   WHERE tipo = 'VENTA'
                   GROUP BY id_lote ORDER BY count(*) DESC LIMIT 1)
  AND m.id_sucursal = 1
ORDER BY m.fecha, m.id_movimiento;

-- a10_kardex_cuadra.png  ·  el kardex coincide con la existencia en todos los lotes
SELECT count(*)                          AS lotes_revisados,
       count(*) FILTER (WHERE NOT cuadra) AS lotes_que_no_cuadran
FROM v_kardex_saldo;

-- a11_auditoria.png  ·  cambios registrados automáticamente por los triggers
SELECT tabla_afectada, operacion, count(*) AS registros
FROM auditoria
GROUP BY tabla_afectada, operacion
ORDER BY tabla_afectada, operacion;

-- a12_auditoria_detalle.png  ·  ejemplo: antes y después de un cambio de inventario
SELECT id_auditoria, tabla_afectada, operacion,
       valor_anterior ->> 'existencia' AS existencia_antes,
       valor_nuevo    ->> 'existencia' AS existencia_despues,
       usuario, fecha
FROM auditoria
WHERE tabla_afectada = 'inventario_lote' AND operacion = 'UPDATE'
ORDER BY id_auditoria
LIMIT 10;


-- ============================================================================
-- REGLAS DE INTEGRIDAD (capturas del ERROR, no del resultado)
-- Cada prueba va dentro de BEGIN ... ROLLBACK, así no deja nada a medias.
-- Ejecuta cada bloque en 2 partes, como el crash test:
--   1) selecciona BEGIN + la instrucción y pulsa Alt + X  -> sale el error (captura)
--   2) selecciona el ROLLBACK y pulsa Ctrl + Enter
-- ============================================================================

-- a13_error_existencia_negativa.png  ·  CHECK: la existencia no puede quedar negativa
BEGIN;
UPDATE inventario_lote SET existencia = -5 WHERE id_lote = 1 AND id_sucursal = 1;
ROLLBACK;

-- a14_error_vencimiento.png  ·  CHECK: un lote no puede vencer antes de fabricarse
BEGIN;
INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento)
VALUES (1, 'LPRUEBA-1', DATE '2026-10-01', DATE '2026-01-01');
ROLLBACK;

-- a15_error_llave_foranea.png  ·  FK: no existe el cliente 9999
BEGIN;
INSERT INTO pedido (id_cliente, id_sucursal, canal) VALUES (9999, 1, 'APP');
ROLLBACK;
