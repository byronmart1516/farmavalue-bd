-- ============================================================================
-- FARMAVALUE - 05_procedimientos.sql (Rol B: lógica transaccional)
-- sp_checkout: checkout atómico con FEFO, bloqueo pesimista y conciliación RF-05
-- Requiere: 01_ddl.sql y 02_carga_inicial.sql
--
-- Versión corregida el 16-oct-2026 sobre la versión original de B (7-oct).
-- Se mantiene la misma firma, así que las llamadas existentes siguen sirviendo.
-- El detalle de cada corrección está en la Bitácora de correcciones.
-- ============================================================================

SET search_path TO farmavalue;

CREATE OR REPLACE PROCEDURE farmavalue.sp_checkout(
    -- Parámetros obligatorios
    p_id_cliente         INT,
    p_id_sucursal        INT,
    p_canal              VARCHAR,       -- 'APP', 'POS', 'CALL_CENTER'
    p_id_pasarela        INT,
    -- Parámetros opcionales
    p_id_empleado        INT     DEFAULT NULL,   -- NULL en pedidos de la App
    p_items_json         JSONB   DEFAULT '[]'::jsonb,
    -- Formato de p_items_json:
    --   [{"id_producto": 5, "cantidad": 2},
    --    {"id_producto": 1, "cantidad": 1, "id_receta": 3}]
    p_usar_puntos        INT     DEFAULT 0,      -- puntos que el cliente quiere canjear
    p_simular_fallo      BOOLEAN DEFAULT FALSE,  -- TRUE solo para el crash test (Rol D)
    -- Resultados
    INOUT p_id_pedido    INT     DEFAULT NULL,
    INOUT p_monto_neto   NUMERIC DEFAULT NULL,   -- lo que la farmacia recibe después de comisión
    INOUT p_estado_pago  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    -- Reglas de negocio (ver Bitácora, sección "Reglas de negocio")
    c_valor_punto        CONSTANT NUMERIC(12,2) := 0.10;  -- 1 punto canjeado = Q0.10
    c_quetzales_x_punto  CONSTANT NUMERIC(12,2) := 10.00; -- se gana 1 punto por cada Q10 pagados

    v_item               RECORD;
    v_lote               RECORD;
    v_requiere_receta    BOOLEAN;
    v_precio             NUMERIC(12,2);
    v_pendiente          INT;
    v_tomar              INT;
    v_id_promocion       INT;
    v_pct_promo          NUMERIC(5,2);
    v_desc_unitario      NUMERIC(12,2);

    v_monto_bruto        NUMERIC(12,2) := 0;   -- suma de cantidad x (precio - descuento promo)
    v_monto_recetado     NUMERIC(12,2) := 0;   -- parte del bruto que corresponde a productos con receta
    v_pct_seguro         NUMERIC(5,2)  := 0;
    v_desc_seguro        NUMERIC(12,2) := 0;
    v_puntos_cliente     INT;
    v_puntos_canje       INT := 0;
    v_desc_puntos        NUMERIC(12,2) := 0;
    v_cobrado            NUMERIC(12,2) := 0;   -- lo que paga el cliente por la pasarela
    v_pct_comision       NUMERIC(5,2);
    v_comision           NUMERIC(12,2) := 0;
    v_puntos_ganados     INT := 0;
BEGIN
    -- 1. Validaciones de entrada
    IF p_items_json IS NULL OR jsonb_typeof(p_items_json) <> 'array'
       OR jsonb_array_length(p_items_json) = 0 THEN
        RAISE EXCEPTION 'El pedido debe contener al menos un producto.';
    END IF;

    IF p_usar_puntos IS NULL OR p_usar_puntos < 0 THEN
        RAISE EXCEPTION 'La cantidad de puntos a canjear no es válida.';
    END IF;

    SELECT comision_pct INTO v_pct_comision
    FROM farmavalue.pasarela WHERE id_pasarela = p_id_pasarela;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'La pasarela % no existe.', p_id_pasarela;
    END IF;

    -- Bloquea la fila del cliente: evita que dos pedidos simultáneos canjeen los mismos puntos
    SELECT c.puntos, COALESCE(a.porcentaje_cobertura, 0)
    INTO v_puntos_cliente, v_pct_seguro
    FROM farmavalue.cliente c
    LEFT JOIN farmavalue.aseguradora a ON a.id_aseguradora = c.id_aseguradora
    WHERE c.id_cliente = p_id_cliente
    FOR UPDATE OF c;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'El cliente % no existe.', p_id_cliente;
    END IF;

    -- 2. Cabecera del pedido
    INSERT INTO farmavalue.pedido (id_cliente, id_sucursal, id_empleado, canal, estado)
    VALUES (p_id_cliente, p_id_sucursal, p_id_empleado, p_canal, 'PENDIENTE')
    RETURNING id_pedido INTO p_id_pedido;

    -- 3. Productos: FEFO completando lotes, con bloqueo pesimista (RNF-01)
    FOR v_item IN
        SELECT * FROM jsonb_to_recordset(p_items_json)
               AS x(id_producto INT, cantidad INT, id_receta INT)
    LOOP
        IF v_item.id_producto IS NULL OR v_item.cantidad IS NULL OR v_item.cantidad <= 0 THEN
            RAISE EXCEPTION 'Cada producto necesita id_producto y una cantidad mayor a 0.';
        END IF;

        SELECT requiere_receta, precio_venta INTO v_requiere_receta, v_precio
        FROM farmavalue.producto WHERE id_producto = v_item.id_producto;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'El producto % no existe.', v_item.id_producto;
        END IF;

        -- Receta obligatoria para productos que la requieren, y debe ser del mismo cliente
        IF v_requiere_receta THEN
            IF v_item.id_receta IS NULL THEN
                RAISE EXCEPTION 'El producto % requiere receta médica.', v_item.id_producto;
            END IF;
            PERFORM 1 FROM farmavalue.receta
            WHERE id_receta = v_item.id_receta AND id_cliente = p_id_cliente;
            IF NOT FOUND THEN
                RAISE EXCEPTION 'La receta % no pertenece al cliente %.', v_item.id_receta, p_id_cliente;
            END IF;
        END IF;

        v_pendiente := v_item.cantidad;

        -- Recorre los lotes vigentes en orden de vencimiento y los bloquea.
        -- Si el primer lote no alcanza, toma lo que tenga y completa con el siguiente.
        FOR v_lote IN
            SELECT il.id_lote, il.existencia - il.reservada AS disponible
            FROM farmavalue.inventario_lote il
            JOIN farmavalue.lote l ON l.id_lote = il.id_lote
            WHERE l.id_producto = v_item.id_producto
              AND il.id_sucursal = p_id_sucursal
              AND l.fecha_vencimiento > CURRENT_DATE
              AND il.existencia - il.reservada > 0
            ORDER BY l.fecha_vencimiento ASC, il.id_lote ASC
            FOR UPDATE OF il
        LOOP
            EXIT WHEN v_pendiente = 0;
            v_tomar := LEAST(v_pendiente, v_lote.disponible);

            -- Promoción vigente del lote, si existe
            SELECT id_promocion, porcentaje_descuento INTO v_id_promocion, v_pct_promo
            FROM farmavalue.promocion
            WHERE id_lote = v_lote.id_lote
              AND activa
              AND CURRENT_DATE BETWEEN fecha_inicio AND fecha_fin
            ORDER BY porcentaje_descuento DESC
            LIMIT 1;
            IF NOT FOUND THEN
                v_id_promocion := NULL;
                v_pct_promo := 0;
            END IF;
            v_desc_unitario := ROUND(v_precio * v_pct_promo / 100, 2);

            UPDATE farmavalue.inventario_lote
            SET existencia = existencia - v_tomar
            WHERE id_lote = v_lote.id_lote AND id_sucursal = p_id_sucursal;

            INSERT INTO farmavalue.detalle_pedido
                (id_pedido, id_lote, id_receta, id_promocion, cantidad, precio_unitario, descuento_unitario)
            VALUES
                (p_id_pedido, v_lote.id_lote,
                 CASE WHEN v_requiere_receta THEN v_item.id_receta END,
                 v_id_promocion, v_tomar, v_precio, v_desc_unitario);

            -- Kardex: toda venta deja su movimiento con cantidad negativa
            INSERT INTO farmavalue.movimiento_inventario
                (id_lote, id_sucursal, tipo, cantidad, id_pedido, id_empleado, observacion)
            VALUES
                (v_lote.id_lote, p_id_sucursal, 'VENTA', -v_tomar, p_id_pedido, p_id_empleado,
                 'Venta pedido ' || p_id_pedido);

            v_monto_bruto := v_monto_bruto + v_tomar * (v_precio - v_desc_unitario);
            IF v_requiere_receta THEN
                v_monto_recetado := v_monto_recetado + v_tomar * (v_precio - v_desc_unitario);
            END IF;

            v_pendiente := v_pendiente - v_tomar;
        END LOOP;

        IF v_pendiente > 0 THEN
            RAISE EXCEPTION 'Stock insuficiente del producto % en la sucursal % (faltan % unidades).',
                v_item.id_producto, p_id_sucursal, v_pendiente;
        END IF;
    END LOOP;

    -- 4. Descuentos: seguro (solo productos con receta) y canje de puntos
    v_desc_seguro := ROUND(v_monto_recetado * v_pct_seguro / 100, 2);

    v_puntos_canje := LEAST(p_usar_puntos, v_puntos_cliente,
                            FLOOR((v_monto_bruto - v_desc_seguro) / c_valor_punto)::INT);
    v_desc_puntos := ROUND(v_puntos_canje * c_valor_punto, 2);

    v_cobrado := v_monto_bruto - v_desc_seguro - v_desc_puntos;

    -- 5. Puntos: se descuentan los canjeados y se suman los ganados
    v_puntos_ganados := FLOOR(v_cobrado / c_quetzales_x_punto)::INT;

    UPDATE farmavalue.cliente
    SET puntos = puntos - v_puntos_canje + v_puntos_ganados
    WHERE id_cliente = p_id_cliente;

    IF v_puntos_canje > 0 THEN
        INSERT INTO farmavalue.movimiento_puntos (id_cliente, id_pedido, puntos)
        VALUES (p_id_cliente, p_id_pedido, -v_puntos_canje);
    END IF;
    IF v_puntos_ganados > 0 THEN
        INSERT INTO farmavalue.movimiento_puntos (id_cliente, id_pedido, puntos)
        VALUES (p_id_cliente, p_id_pedido, v_puntos_ganados);
    END IF;

    -- 6. Crash test (Rol D): falla después de tocar inventario, kardex y puntos.
    --    Como todo está en la misma transacción, el error deshace todo.
    IF p_simular_fallo THEN
        RAISE EXCEPTION 'Simulación de fallo de pasarela: el cobro no se completó (se deshace todo el pedido).';
    END IF;

    -- 7. Conciliación financiera al centavo (RF-05)
    --    comision_pct se guarda como porcentaje (3.50 = 3.50 %), por eso se divide entre 100
    v_comision   := ROUND(v_cobrado * v_pct_comision / 100, 2);
    p_monto_neto := v_cobrado - v_comision;

    INSERT INTO farmavalue.intento_pago
        (id_pedido, id_pasarela, monto, estado, codigo_respuesta, mensaje)
    VALUES
        (p_id_pedido, p_id_pasarela, v_cobrado, 'APROBADO', '00', 'Transacción aprobada');

    INSERT INTO farmavalue.pago
        (id_pedido, id_pasarela, monto_bruto, descuento_seguro, descuento_puntos, comision, monto_neto)
    VALUES
        (p_id_pedido, p_id_pasarela, v_monto_bruto, v_desc_seguro, v_desc_puntos, v_comision, p_monto_neto);

    UPDATE farmavalue.pedido SET estado = 'PAGADO' WHERE id_pedido = p_id_pedido;

    p_estado_pago := 'APROBADO';
    -- Sin COMMIT aquí: quien llama decide (CALL suelto en autocommit, o dentro de BEGIN ... COMMIT)
END;
$$;
