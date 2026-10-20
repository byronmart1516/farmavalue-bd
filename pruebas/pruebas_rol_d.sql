-- ============================================================================
-- PROYECTO FARMAVALUE - ROL D: PRUEBAS Y PROTOTIPO
-- Entregables 4 (concurrencia) y 5 (crash test)
-- Requiere: 01_ddl.sql, 02_carga_inicial.sql y 05_procedimientos.sql
--
-- Versión 2 (16-oct-2026): las pruebas usan el sp_checkout real y el lote
-- crítico LCRIT-001. La versión 1 de D se conserva al final como prueba 1-B.
--
-- Se pueden correr antes o después del poblado (03): el poblado nunca vende
-- P002 en Zona 10, así que LCRIT-001 conserva su única caja. Para repetir la
-- prueba 1, volver a cargar la base desde cero (01, 02, 05).
-- ============================================================================


-- ============================================================================
-- PRUEBA 1: CONCURRENCIA - DOS CANALES COMPRAN LA ÚLTIMA CAJA DEL LOTE CRÍTICO
-- Requerimiento: demostrar que FOR UPDATE evita la sobreventa (RNF-01).
--
-- Escenario: LCRIT-001 (Azitromicina, P002) tiene 1 sola caja en Zona 10.
--   Sesión A = Cliente App (cliente 8, receta 1)
--   Sesión B = Caja POS    (cliente 4, receta 9, cajero 2)
--
-- Se necesitan DOS editores SQL de DBeaver abiertos sobre farmavalue, uno por
-- sesión, y ejecutar cada bloque en el orden indicado (seleccionar el bloque
-- y presionar Alt + X). Grabar la pantalla con las dos ventanas visibles.
-- ============================================================================

-- >>> PASO 0 (cualquier sesión): estado inicial
SET search_path TO farmavalue;
SELECT l.numero_lote, l.fecha_vencimiento, il.existencia
FROM inventario_lote il
JOIN lote l ON l.id_lote = il.id_lote
WHERE l.id_producto = 2 AND il.id_sucursal = 1
ORDER BY l.fecha_vencimiento;
-- Esperado: LCRIT-001 con existencia 1 es el primero (vence antes).


-- >>> PASO 1 - SESIÓN A (App): inicia la compra y NO confirma todavía
SET search_path TO farmavalue;
BEGIN;
CALL sp_checkout(8, 1, 'APP', 1, NULL,
                 '[{"id_producto": 2, "cantidad": 1, "id_receta": 1}]'::jsonb);
-- La sesión A ya tomó LCRIT-001 y tiene la fila bloqueada. NO ejecutar COMMIT aún.


-- >>> PASO 2 - SESIÓN B (POS): intenta comprar la misma caja
SET search_path TO farmavalue;
BEGIN;
CALL sp_checkout(4, 1, 'POS', 1, 2,
                 '[{"id_producto": 2, "cantidad": 1, "id_receta": 9}]'::jsonb);
-- Esperado: la sesión B se queda ESPERANDO (DBeaver muestra la consulta en ejecución).
-- No puede leer LCRIT-001 mientras A no termine: esto es el bloqueo pesimista.


-- >>> PASO 3 - SESIÓN A: confirma su compra
COMMIT;
-- En ese instante la sesión B se desbloquea. Como LCRIT-001 ya quedó en 0,
-- FEFO le asigna el siguiente lote (LP002-1). La misma caja NO se vendió dos veces.


-- >>> PASO 4 - SESIÓN B: confirma su compra
COMMIT;


-- >>> PASO 5 (cualquier sesión): verificación
SELECT p.id_pedido, p.canal, l.numero_lote, d.cantidad
FROM pedido p
JOIN detalle_pedido d ON d.id_pedido = p.id_pedido
JOIN lote l           ON l.id_lote   = d.id_lote
WHERE l.id_producto = 2 AND p.id_sucursal = 1
ORDER BY p.id_pedido;
-- Esperado: pedido de APP con LCRIT-001 y pedido de POS con LP002-1.

SELECT l.numero_lote, il.existencia
FROM inventario_lote il JOIN lote l ON l.id_lote = il.id_lote
WHERE l.numero_lote = 'LCRIT-001';
-- Esperado: existencia 0 (nunca -1).


-- ============================================================================
-- PRUEBA 2: CRASH TEST - FALLO DE PASARELA A MITAD DEL CHECKOUT
-- Requerimiento: verificar que, tras el ROLLBACK, el inventario y los puntos
-- quedan intactos (atomicidad).
--
-- sp_checkout con p_simular_fallo = TRUE descuenta inventario, escribe el kardex
-- y mueve puntos, y justo antes de cobrar lanza un error de pasarela.
-- DBeaver se detiene en el error, así que se ejecuta en 4 partes, en el mismo
-- editor: seleccionar cada parte y ejecutarla (Alt + X o Ctrl + Enter).
-- Verificado el 17-oct: antes y después 85 / 26 / 244 (idénticos).
-- ============================================================================

SET search_path TO farmavalue;

-- PARTE 1: estado ANTES (seleccionar el SET y este SELECT)
SELECT 'antes' AS momento,
       (SELECT sum(il.existencia) FROM inventario_lote il JOIN lote l ON l.id_lote = il.id_lote
         WHERE l.id_producto = 5 AND il.id_sucursal = 1)               AS existencia_p005_zona10,
       (SELECT puntos FROM cliente WHERE id_cliente = 1)                AS puntos_cliente_1,
       (SELECT count(*) FROM pedido)                                    AS pedidos,
       (SELECT count(*) FROM movimiento_inventario)                     AS movimientos_kardex;

-- PARTE 2: la compra que falla (seleccionar BEGIN y el CALL)
BEGIN;
CALL sp_checkout(1, 1, 'POS', 1, 2,
                 '[{"id_producto": 5, "cantidad": 2}]'::jsonb,
                 20,      -- canjea 20 puntos
                 TRUE);   -- simula el fallo de la pasarela
-- Esperado: ERROR "Simulación de fallo de pasarela..."

-- PARTE 3: deshacer (seleccionar y Ctrl + Enter)
ROLLBACK;

-- PARTE 4: estado DESPUÉS, debe ser idéntico al de ANTES
SELECT 'despues' AS momento,
       (SELECT sum(il.existencia) FROM inventario_lote il JOIN lote l ON l.id_lote = il.id_lote
         WHERE l.id_producto = 5 AND il.id_sucursal = 1)               AS existencia_p005_zona10,
       (SELECT puntos FROM cliente WHERE id_cliente = 1)                AS puntos_cliente_1,
       (SELECT count(*) FROM pedido)                                    AS pedidos,
       (SELECT count(*) FROM movimiento_inventario)                     AS movimientos_kardex;


-- ============================================================================
-- PRUEBA 1-B (versión 1 de D): bloqueo con NOWAIT
-- Variante que muestra el error de bloqueo de inmediato en lugar de esperar.
-- Ahora bloquea la fila de inventario del lote crítico en Zona 10.
-- ============================================================================

-- >>> SESIÓN A
SET search_path TO farmavalue;
BEGIN;
SELECT il.id_lote, il.id_sucursal, il.existencia
FROM inventario_lote il JOIN lote l ON l.id_lote = il.id_lote
WHERE l.numero_lote = 'LCRIT-001' AND il.id_sucursal = 1
FOR UPDATE OF il;
-- (no confirmar todavía)

-- >>> SESIÓN B
SET search_path TO farmavalue;
BEGIN;
SELECT il.id_lote, il.id_sucursal, il.existencia
FROM inventario_lote il JOIN lote l ON l.id_lote = il.id_lote
WHERE l.numero_lote = 'LCRIT-001' AND il.id_sucursal = 1
FOR UPDATE OF il NOWAIT;
-- Esperado: ERROR 55P03 "could not obtain lock on row" (no se pudo bloquear la fila)
ROLLBACK;

-- >>> SESIÓN A
ROLLBACK;
