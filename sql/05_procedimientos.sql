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

-- PROCEDIMIENTOS DE RESERVAS (ROL B - RF-03)
-- 1. sp_reservar
-- Reserva stock aplicando FEFO con bloqueo pesimista
CREATE OR REPLACE PROCEDURE farmavalue.sp_reservar(
    p_id_cliente INT,
    p_id_sucursal INT,
    p_id_producto INT,
    p_cantidad INT,
    p_minutos INT DEFAULT 10
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
    v_restante INT := p_cantidad;
    v_disponible INT;
    v_a_reservar INT;
    v_total_disponible INT;
BEGIN
    IF p_cantidad <= 0 THEN
        RAISE EXCEPTION 'La cantidad a reservar debe ser mayor a 0.';
    END IF;

    -- Verificar disponibilidad total antes de reservar
    SELECT COALESCE(SUM(existencia - reservada), 0)
    INTO v_total_disponible
    FROM farmavalue.inventario_lote il
    JOIN farmavalue.lote l ON il.id_lote = l.id_lote
    WHERE il.id_sucursal = p_id_sucursal
      AND l.id_producto = p_id_producto
      AND l.fecha_vencimiento > CURRENT_DATE;

    IF v_total_disponible < p_cantidad THEN
        RAISE EXCEPTION 'Stock insuficiente para reservar. Disponible: %, Solicitado: %', v_total_disponible, p_cantidad;
    END IF;

    -- FEFO: Recorrer lotes ordenados por fecha de vencimiento con FOR UPDATE
    FOR v_rec IN
        SELECT il.id_lote, il.existencia, il.reservada, (il.existencia - il.reservada) AS disponible
        FROM farmavalue.inventario_lote il
        JOIN farmavalue.lote l ON il.id_lote = l.id_lote
        WHERE il.id_sucursal = p_id_sucursal
          AND l.id_producto = p_id_producto
          AND l.fecha_vencimiento > CURRENT_DATE
          AND (il.existencia - il.reservada) > 0
        ORDER BY l.fecha_vencimiento ASC
        FOR UPDATE OF il
    LOOP
        EXIT WHEN v_restante <= 0;

        v_a_reservar := LEAST(v_rec.disponible, v_restante);

        -- Incrementar el stock reservado en inventario_lote
        UPDATE farmavalue.inventario_lote
        SET reservada = reservada + v_a_reservar
        WHERE id_sucursal = p_id_sucursal AND id_lote = v_rec.id_lote;

        -- Registrar la fila de reserva en estado ACTIVA
        INSERT INTO farmavalue.reserva (
            id_cliente, id_lote, id_sucursal, cantidad, creada_en, expira_en, estado
        ) VALUES (
            p_id_cliente, v_rec.id_lote, p_id_sucursal, v_a_reservar, NOW(), NOW() + (p_minutos || ' minutes')::INTERVAL, 'ACTIVA'
        );

        v_restante := v_restante - v_a_reservar;
    END LOOP;
END;
$$;


-- 2. sp_confirmar_reserva
-- Confirma la reserva, libera el stock reservado y ejecuta el cobro con sp_checkout
CREATE OR REPLACE PROCEDURE farmavalue.sp_confirmar_reserva(
    p_id_reserva INT,
    p_canal VARCHAR,
    p_id_pasarela INT,
    p_id_empleado INT,
    p_usar_puntos INT DEFAULT 0,
    INOUT p_id_pedido INT DEFAULT NULL,
    INOUT p_monto_neto NUMERIC DEFAULT NULL,
    INOUT p_estado_pago VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_reserva RECORD;
    v_items_json JSONB;
    v_id_receta INT;
BEGIN
    -- Bloquear y obtener la reserva
    SELECT r.*, l.id_producto
    INTO v_reserva
    FROM farmavalue.reserva r
    JOIN farmavalue.lote l ON r.id_lote = l.id_lote
    WHERE r.id_reserva = p_id_reserva
    FOR UPDATE OF r;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La reserva con ID % no existe.', p_id_reserva;
    END IF;

    IF v_reserva.estado != 'ACTIVA' THEN
        RAISE EXCEPTION 'La reserva no esta ACTIVA (Estado actual: %).', v_reserva.estado;
    END IF;

    IF v_reserva.expira_en < NOW() THEN
        -- Si ya expiro, se marca como EXPIRADA y se libera el stock
        UPDATE farmavalue.reserva SET estado = 'EXPIRADA' WHERE id_reserva = p_id_reserva;
        UPDATE farmavalue.inventario_lote 
        SET reservada = reservada - v_reserva.cantidad 
        WHERE id_sucursal = v_reserva.id_sucursal AND id_lote = v_reserva.id_lote;
        
        RAISE EXCEPTION 'La reserva % ha expirado y fue liberada.', p_id_reserva;
    END IF;

    -- Descontar el stock reservado antes de procesar la venta
    UPDATE farmavalue.inventario_lote
    SET reservada = reservada - v_reserva.cantidad
    WHERE id_sucursal = v_reserva.id_sucursal AND id_lote = v_reserva.id_lote;

    -- Cambiar estado a CONFIRMADA
    UPDATE farmavalue.reserva
    SET estado = 'CONFIRMADA'
    WHERE id_reserva = p_id_reserva;

    -- Buscar la receta valida si el producto la requiere
    SELECT id_receta INTO v_id_receta
    FROM farmavalue.receta
    WHERE id_cliente = v_reserva.id_cliente 
      AND id_producto = v_reserva.id_producto 
      AND NOT usada 
      AND fecha_emision <= CURRENT_DATE
    LIMIT 1;

    -- Armar el JSON del producto
    IF v_id_receta IS NOT NULL THEN
        v_items_json := jsonb_build_array(
            jsonb_build_object('id_producto', v_reserva.id_producto, 'cantidad', v_reserva.cantidad, 'id_receta', v_id_receta)
        );
    ELSE
        v_items_json := jsonb_build_array(
            jsonb_build_object('id_producto', v_reserva.id_producto, 'cantidad', v_reserva.cantidad)
        );
    END IF;

    -- Procesar la compra mediante el procedimiento principal
    CALL farmavalue.sp_checkout(
        p_id_cliente   => v_reserva.id_cliente,
        p_id_sucursal  => v_reserva.id_sucursal,
        p_canal        => p_canal,
        p_id_pasarela  => p_id_pasarela,
        p_id_empleado  => p_id_empleado,
        p_items_json   => v_items_json,
        p_usar_puntos  => p_usar_puntos,
        p_id_pedido    => p_id_pedido,
        p_monto_neto   => p_monto_neto,
        p_estado_pago  => p_estado_pago
    );
END;
$$;


-- 3. sp_liberar_reservas
-- Libera automáticamente las reservas expiradas (invocado manualmente o por pg_cron)
CREATE OR REPLACE PROCEDURE farmavalue.sp_liberar_reservas(
    OUT p_liberadas INT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec RECORD;
BEGIN
    p_liberadas := 0;

    -- Buscar reservas expiradas evitando bloqueos concurrentes con SKIP LOCKED
    FOR v_rec IN
        SELECT id_reserva, id_sucursal, id_lote, cantidad
        FROM farmavalue.reserva
        WHERE estado = 'ACTIVA'
          AND expira_en < NOW()
        FOR UPDATE SKIP LOCKED
    LOOP
        -- Restar del inventario reservado
        UPDATE farmavalue.inventario_lote
        SET reservada = reservada - v_rec.cantidad
        WHERE id_sucursal = v_rec.id_sucursal AND id_lote = v_rec.id_lote;

        -- Marcar la reserva como EXPIRADA
        UPDATE farmavalue.reserva
        SET estado = 'EXPIRADA'
        WHERE id_reserva = v_rec.id_reserva;

        p_liberadas := p_liberadas + 1;
    END LOOP;
END;
$$;


-- Reservar 2 unidades del producto P001 en Zona 10 (Sucursal 1) para el cliente 8
CALL farmavalue.sp_reservar(p_id_cliente => 8, p_id_sucursal => 1, p_id_producto => 1, p_cantidad => 2, p_minutos => 10);

-- Verificar que aumentó la columna 'reservada'
SELECT id_lote, existencia, reservada FROM farmavalue.inventario_lote WHERE id_sucursal = 1 AND reservada > 0;