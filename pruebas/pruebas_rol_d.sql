-- ============================================================================
-- PROYECTO FARMAVALUE - ROL D: PRUEBAS Y PROTOTIPO
-- SCRIPTS DE EVALUACIÓN DE CONCURRENCIA, INTEGRIDAD Y RECUPERACIÓN (CRASH TEST)
-- ============================================================================

SET search_path TO farmavalue, public;

-- ============================================================================
-- PRUEBA 1: SIMULACIÓN DE CONCURRENCIA CON BLOQUEO PESIMISTA (FOR UPDATE)
-- REQUERIMIENTO: Demostrar cómo se evita la sobreventa entre App Móvil y POS Física.
-- ============================================================================

-- >>> EJECUTAR EN SESIÓN A (Cliente App Móvil / Pestaña 1) <<<
BEGIN;

SELECT l.id_lote, l.id_producto, l.numero_lote, i.existencia, l.fecha_vencimiento
FROM farmavalue.lote l
JOIN farmavalue.inventario_lote i ON l.id_lote = i.id_lote
WHERE l.id_producto = 1 AND i.existencia > 0
ORDER BY l.fecha_vencimiento ASC
LIMIT 1
FOR UPDATE OF l;

-- (NOTA: MANTENER LA SESIÓN A EN ESTADO PENDIENTE / SIN HACER ROLLBACK NI COMMIT)


-- >>> EJECUTAR EN SESIÓN B (Cajero POS / Pestaña 2) <<<
BEGIN;

SELECT l.id_lote, l.id_producto, l.numero_lote, i.existencia
FROM farmavalue.lote l
JOIN farmavalue.inventario_lote i ON l.id_lote = i.id_lote
WHERE l.id_producto = 1 AND i.existencia > 0
ORDER BY l.fecha_vencimiento ASC
LIMIT 1
FOR UPDATE OF l NOWAIT;
-- Lanza el error de bloqueo evitando sobreventa.

-- Finalizar Sesiones de Prueba:
ROLLBACK;


-- ============================================================================
-- PRUEBA 2: PRUEBA DE RECUPERACIÓN TRANSACCIONAL (CRASH TEST / ROLLBACK)
-- REQUERIMIENTO: Error forzado a mitad del Checkout para verificar atomicidad.
-- ============================================================================

-- Estado Inicial de Verificación
SELECT id_lote, id_sucursal, existencia FROM farmavalue.inventario_lote WHERE id_lote = 1 AND id_sucursal = 1;
SELECT id_cliente, puntos FROM farmavalue.cliente WHERE id_cliente = 1;

-- INICIO DEL CHECKOUT (SIMULACIÓN DE FALLA A MITAD DE PROCESO)
BEGIN;

  -- Paso 1: Descuento de stock en inventario
  UPDATE farmavalue.inventario_lote 
  SET existencia = existencia - 1 
  WHERE id_lote = 1 AND id_sucursal = 1;

  -- Paso 2: Asignación/Uso de puntos de cliente
  UPDATE farmavalue.cliente 
  SET puntos = puntos + 10 
  WHERE id_cliente = 1;

  -- Paso 3: SIMULACIÓN DE FALLO DE PASARELA (FK inexistente en id_pedido para forzar error)
  INSERT INTO farmavalue.pago (id_pedido, id_pasarela, monto_bruto, monto_neto)
  VALUES (999999, 1, 150.00, 150.00);

-- Al fallar por clave foránea, se revierte toda la transacción:
ROLLBACK;

-- VERIFICACIÓN POST-CRASH (Demuestra que NO se modificó inventario ni puntos)
SELECT id_lote, id_sucursal, existencia FROM farmavalue.inventario_lote WHERE id_lote = 1 AND id_sucursal = 1;
SELECT id_cliente, puntos FROM farmavalue.cliente WHERE id_cliente = 1;