-- ============================================================================
-- FARMAVALUE - 03_poblado.sql (Rol A: poblado extendido, Entregable 6)
-- Genera 200+ pedidos llamando a sp_checkout, así inventario, kardex, pagos y
-- puntos quedan coherentes. También deja datos en reserva e intento_pago para
-- que todas las tablas tengan filas.
--
-- ORDEN DE EJECUCIÓN: 01_ddl -> 02_carga_inicial -> 05_procedimientos -> 03_poblado -> 04_vistas
-- Ejecutar UNA sola vez sobre una base recién cargada (Alt + X en DBeaver).
-- Las pruebas de concurrencia y crash test (Rol D) se hacen ANTES de este script.
-- ============================================================================

SET search_path TO farmavalue;

-- Semilla fija: cada vez que se corre desde cero salen los mismos pedidos
SELECT setseed(0.2026);

-- ----------------------------------------------------------------------------
-- 1. Pedidos de venta: 230 intentos (algunos se rechazan por stock, como en la vida real)
-- ----------------------------------------------------------------------------
DO $$
DECLARE
    i          INT;
    k          INT;
    v_ok       INT := 0;
    v_fallos   INT := 0;
    v_cliente  INT;
    v_sucursal INT;
    v_canal    TEXT;
    v_empleado INT;
    v_pasarela INT;
    v_receta   INT;
    v_items    JSONB;
    v_usados   INT[];
    v_prod     INT;
    v_cant     INT;
    v_receta_obl BOOLEAN;
    v_puntos   INT;
    v_id       INT;
    v_neto     NUMERIC;
    v_estado   VARCHAR;
BEGIN
    FOR i IN 1..230 LOOP
        v_cliente  := 1 + floor(random() * 60)::INT;
        v_sucursal := 1 + floor(random() * 2)::INT;          -- solo farmacias (1 y 2)
        v_canal    := (ARRAY['APP', 'POS', 'CALL_CENTER'])[1 + floor(random() * 3)::INT];

        -- Empleado según canal y sucursal (ids de 02_carga_inicial.sql)
        v_empleado := CASE v_canal
                        WHEN 'APP' THEN NULL
                        WHEN 'POS' THEN CASE v_sucursal WHEN 1 THEN 2 ELSE 6 END   -- cajeros
                        ELSE            CASE v_sucursal WHEN 1 THEN 3 ELSE 7 END   -- call center
                      END;

        -- La App solo acepta tarjeta (VisaNet o BAC); POS y call center también efectivo
        v_pasarela := CASE WHEN v_canal = 'APP' THEN 1 + floor(random() * 2)::INT
                           ELSE 1 + floor(random() * 3)::INT END;

        -- Una receta del cliente, si tiene (si no, solo compra productos sin receta)
        SELECT id_receta INTO v_receta
        FROM receta WHERE id_cliente = v_cliente
        ORDER BY random() LIMIT 1;
        IF NOT FOUND THEN v_receta := NULL; END IF;

        -- De 1 a 3 productos distintos, de 1 a 3 unidades cada uno
        v_items  := '[]'::jsonb;
        v_usados := '{}';
        FOR k IN 1..(1 + floor(random() * 3)::INT) LOOP
            SELECT id_producto, requiere_receta INTO v_prod, v_receta_obl
            FROM producto
            WHERE (v_receta IS NOT NULL OR NOT requiere_receta)
              AND id_producto <> ALL (v_usados)
              AND NOT (id_producto = 2 AND v_sucursal = 1)   -- no tocar P002 en Zona 10 (lote crítico)
            ORDER BY random() LIMIT 1;

            v_usados := v_usados || v_prod;
            v_cant   := 1 + floor(random() * 3)::INT;

            IF v_receta_obl THEN
                v_items := v_items || jsonb_build_object('id_producto', v_prod, 'cantidad', v_cant,
                                                         'id_receta', v_receta);
            ELSE
                v_items := v_items || jsonb_build_object('id_producto', v_prod, 'cantidad', v_cant);
            END IF;
        END LOOP;

        -- 1 de cada 5 pedidos intenta canjear 50 puntos
        v_puntos := CASE WHEN random() < 0.2 THEN 50 ELSE 0 END;

        BEGIN
            v_id := NULL; v_neto := NULL; v_estado := NULL;
            CALL sp_checkout(v_cliente, v_sucursal, v_canal, v_pasarela, v_empleado,
                             v_items, v_puntos, FALSE, v_id, v_neto, v_estado);
            v_ok := v_ok + 1;
        EXCEPTION WHEN OTHERS THEN
            v_fallos := v_fallos + 1;
            RAISE NOTICE 'Intento % rechazado: %', i, SQLERRM;
        END;
    END LOOP;

    RAISE NOTICE 'Pedidos creados: %, rechazados: %', v_ok, v_fallos;
END $$;

-- ----------------------------------------------------------------------------
-- 2. Pagos rechazados por la pasarela (rechazo controlado: pedido ANULADO + intento RECHAZADO)
--    No tocan inventario: el cobro falló antes de despachar.
-- ----------------------------------------------------------------------------
WITH nuevos AS (
    INSERT INTO pedido (id_cliente, id_sucursal, id_empleado, canal, estado)
    SELECT 1 + (n * 11) % 60,
           1 + n % 2,
           CASE WHEN n % 3 = 0 THEN NULL WHEN n % 2 = 1 THEN 2 ELSE 6 END,
           CASE WHEN n % 3 = 0 THEN 'APP' ELSE 'POS' END,
           'ANULADO'
    FROM generate_series(1, 12) AS n
    RETURNING id_pedido, id_cliente
)
INSERT INTO intento_pago (id_pedido, id_pasarela, monto, estado, codigo_respuesta, mensaje)
SELECT id_pedido,
       1 + id_pedido % 2,
       round((50 + random() * 300)::numeric, 2),
       CASE WHEN id_pedido % 4 = 0 THEN 'ERROR' ELSE 'RECHAZADO' END,
       CASE WHEN id_pedido % 4 = 0 THEN '96' ELSE '51' END,
       CASE WHEN id_pedido % 4 = 0 THEN 'Error de comunicación con la pasarela'
            ELSE 'Fondos insuficientes' END
FROM nuevos;

-- ----------------------------------------------------------------------------
-- 3. Historial de reservas pick-up (ya cerradas: no afectan "reservada")
-- ----------------------------------------------------------------------------
INSERT INTO reserva (id_cliente, id_lote, id_sucursal, cantidad, creada_en, expira_en, estado)
SELECT 1 + (n * 7) % 60,
       il.id_lote,
       il.id_sucursal,
       1 + n % 2,
       t.creada,
       t.creada + interval '10 minutes',
       CASE WHEN n % 3 = 0 THEN 'CONFIRMADA' ELSE 'EXPIRADA' END
FROM generate_series(1, 20) AS n
CROSS JOIN LATERAL (SELECT now() - (n * 4 || ' days')::interval - (n || ' hours')::interval AS creada) t
CROSS JOIN LATERAL (
    SELECT il.id_lote, il.id_sucursal
    FROM inventario_lote il
    JOIN lote l ON l.id_lote = il.id_lote
    WHERE il.id_sucursal IN (1, 2) AND l.numero_lote <> 'LCRIT-001'
    ORDER BY il.id_lote, il.id_sucursal
    OFFSET (n * 5) % 100 LIMIT 1
) il;

-- ----------------------------------------------------------------------------
-- 4. Repartir los pedidos en los últimos 90 días para que los reportes por mes tengan datos.
--    El trigger de auditoría de pago se pausa: es un ajuste de datos de prueba, no un cambio real.
-- ----------------------------------------------------------------------------
CREATE TEMP TABLE t_fechas AS
SELECT id_pedido, now() - random() * interval '90 days' AS fecha
FROM pedido;

ALTER TABLE pago DISABLE TRIGGER trg_aud_pago;

UPDATE pedido p                SET fecha = t.fecha FROM t_fechas t WHERE p.id_pedido = t.id_pedido;
UPDATE pago pa                 SET fecha = t.fecha FROM t_fechas t WHERE pa.id_pedido = t.id_pedido;
UPDATE intento_pago ip         SET fecha = t.fecha FROM t_fechas t WHERE ip.id_pedido = t.id_pedido;
UPDATE movimiento_inventario m SET fecha = t.fecha FROM t_fechas t WHERE m.id_pedido = t.id_pedido;
UPDATE movimiento_puntos mp    SET fecha = t.fecha FROM t_fechas t WHERE mp.id_pedido = t.id_pedido;

ALTER TABLE pago ENABLE TRIGGER trg_aud_pago;

DROP TABLE t_fechas;
