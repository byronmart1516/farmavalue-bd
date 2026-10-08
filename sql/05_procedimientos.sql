SET search_path = farmavalue, public;

CREATE OR REPLACE PROCEDURE farmavalue.sp_checkout(
    -- Parámetros IN obligatorios
    p_id_cliente         INT,
    p_id_sucursal        INT,
    p_canal              VARCHAR,       -- 'APP', 'POS', 'CALL_CENTER'
    p_id_pasarela        INT,
    -- Parámetros IN opcionales (con DEFAULT)
    p_id_empleado        INT DEFAULT NULL,
    p_items_json         JSONB DEFAULT '[]'::jsonb,
    p_usar_puntos        INT DEFAULT 0,
    p_simular_fallo      BOOLEAN DEFAULT FALSE,
    -- Parámetros OUT (al final)
    INOUT p_id_pedido    INT DEFAULT NULL,
    INOUT p_monto_neto   NUMERIC DEFAULT NULL,
    INOUT p_estado_pago  VARCHAR DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_rec_item           RECORD;
    v_id_lote            INT;
    v_existencia_lote    INT;
    v_precio_unitario    NUMERIC(10,2);
    v_subtotal_item      NUMERIC(12,2);
    v_monto_bruto        NUMERIC(12,2) := 0;
    v_pct_comision       NUMERIC(5,4) := 0;
    v_comision_pasarela  NUMERIC(12,2) := 0;
BEGIN
    -- 1. Validar que el JSON traiga productos
    IF p_items_json IS NULL OR jsonb_array_length(p_items_json) = 0 THEN
        RAISE EXCEPTION 'El pedido debe contener al menos un producto.';
    END IF;

    -- 2. Crear cabecera del pedido (Estado PENDIENTE)
    INSERT INTO farmavalue.pedido (id_cliente, id_sucursal, canal, id_empleado, estado)
    VALUES (p_id_cliente, p_id_sucursal, p_canal, p_id_empleado, 'PENDIENTE')
    RETURNING id_pedido INTO p_id_pedido;

    -- 3. Iterar productos aplicando regla FEFO y Bloqueo Pesimista (FOR UPDATE)
    FOR v_rec_item IN SELECT * FROM jsonb_to_recordset(p_items_json) AS x(id_producto INT, cantidad INT, id_receta INT)
    LOOP
        -- Buscar el lote que vence primero con stock suficiente
        SELECT il.id_lote, il.existencia, COALESCE(l.precio_unitario, 10.00)
        INTO v_id_lote, v_existencia_lote, v_precio_unitario
        FROM farmavalue.inventario_lote il
        JOIN farmavalue.lote l ON l.id_lote = il.id_lote
        WHERE l.id_producto = v_rec_item.id_producto
          AND il.id_sucursal = p_id_sucursal
          AND (il.existencia - il.reservada) >= v_rec_item.cantidad
          AND l.fecha_vencimiento > CURRENT_DATE
        ORDER BY l.fecha_vencimiento ASC
        LIMIT 1
        FOR UPDATE; -- RNF-01: Evita sobreventa concurrente

        -- Si no hay stock en lotes vigentes, detiene y deshace todo (ROLLBACK)
        IF v_id_lote IS NULL THEN
            RAISE EXCEPTION 'Stock insuficiente o producto vencido para ID %', v_rec_item.id_producto;
        END IF;

        -- Descontar existencia de inventario
        UPDATE farmavalue.inventario_lote
        SET existencia = existencia - v_rec_item.cantidad
        WHERE id_sucursal = p_id_sucursal AND id_lote = v_id_lote;

        -- Registrar línea de detalle del pedido
        v_subtotal_item := v_precio_unitario * v_rec_item.cantidad;
        v_monto_bruto := v_monto_bruto + v_subtotal_item;

        INSERT INTO farmavalue.detalle_pedido (id_pedido, id_lote, cantidad, precio_unitario, subtotal, id_receta)
        VALUES (p_id_pedido, v_id_lote, v_rec_item.cantidad, v_precio_unitario, v_subtotal_item, v_rec_item.id_receta);

        -- Registrar movimiento en el kardex de inventario
        INSERT INTO farmavalue.movimiento_inventario (id_sucursal, id_lote, tipo, cantidad)
        VALUES (p_id_sucursal, v_id_lote, 'VENTA', -v_rec_item.cantidad);

    END LOOP;

    -- 4. Simular fallo de pasarela para Crash Test (Rol D)
    IF p_simular_fallo THEN
        RAISE EXCEPTION 'Simulación de fallo de pasarela (ROLLBACK forzado).';
    END IF;

    -- 5. Conciliación Financiera (RF-05)
    SELECT porcentaje_comision INTO v_pct_comision 
    FROM farmavalue.pasarela WHERE id_pasarela = p_id_pasarela;

    p_monto_neto := ROUND(v_monto_bruto, 2);
    v_comision_pasarela := ROUND(p_monto_neto * COALESCE(v_pct_comision, 0), 2);

    INSERT INTO farmavalue.pago (id_pedido, id_pasarela, monto_bruto, comision_pasarela, monto_neto, estado)
    VALUES (p_id_pedido, p_id_pasarela, v_monto_bruto, v_comision_pasarela, p_monto_neto, 'COMPLETADO');

    UPDATE farmavalue.pedido SET estado = 'FINALIZADO' WHERE id_pedido = p_id_pedido;

    p_estado_pago := 'APROBADO';
END;
$$;

SELECT column_name, data_type 
FROM information_schema.columns 
WHERE table_schema = 'farmavalue' 
  AND table_name IN ('producto', 'lote');