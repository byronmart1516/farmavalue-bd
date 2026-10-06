DROP SCHEMA IF EXISTS farmavalue CASCADE;
CREATE SCHEMA farmavalue;
SET search_path TO farmavalue;

-- ===== Catálogo e inventario =====
CREATE TABLE sucursal (
  id_sucursal   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre        VARCHAR(80)  NOT NULL,
  tipo          VARCHAR(20)  NOT NULL,   -- FARMACIA o BODEGA
  direccion     VARCHAR(200),
  telefono      VARCHAR(20)
);

CREATE TABLE categoria (
  id_categoria  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre        VARCHAR(60) NOT NULL
);

CREATE TABLE laboratorio (
  id_laboratorio INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre         VARCHAR(80) NOT NULL
);

CREATE TABLE producto (
  id_producto     INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  codigo          VARCHAR(20)  NOT NULL,
  nombre          VARCHAR(120) NOT NULL,
  id_categoria    INT NOT NULL REFERENCES categoria,
  id_laboratorio  INT NOT NULL REFERENCES laboratorio,
  requiere_receta BOOLEAN NOT NULL DEFAULT FALSE,
  precio_venta    NUMERIC(12,2) NOT NULL
);

CREATE TABLE lote (
  id_lote            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_producto        INT NOT NULL REFERENCES producto,
  numero_lote        VARCHAR(30) NOT NULL,
  fecha_fabricacion  DATE NOT NULL,
  fecha_vencimiento  DATE NOT NULL
);

CREATE TABLE inventario_lote (
  id_lote      INT NOT NULL REFERENCES lote,
  id_sucursal  INT NOT NULL REFERENCES sucursal,
  existencia   INT NOT NULL DEFAULT 0,
  reservada    INT NOT NULL DEFAULT 0,
  PRIMARY KEY (id_lote, id_sucursal)
);

-- ===== Personas =====
CREATE TABLE aseguradora (
  id_aseguradora       INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre               VARCHAR(80) NOT NULL,
  porcentaje_cobertura NUMERIC(5,2) NOT NULL
);

CREATE TABLE cliente (
  id_cliente      INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre          VARCHAR(120) NOT NULL,
  nit             VARCHAR(15),
  telefono        VARCHAR(20),
  email           VARCHAR(120),
  id_aseguradora  INT REFERENCES aseguradora,   -- puede ser NULL
  puntos          INT NOT NULL DEFAULT 0
);

CREATE TABLE empleado (                          -- NUEVA
  id_empleado  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre       VARCHAR(120) NOT NULL,
  puesto       VARCHAR(20)  NOT NULL,   -- DEPENDIENTE, CAJERO, AGENTE_CALL, BODEGUERO, ADMIN
  id_sucursal  INT NOT NULL REFERENCES sucursal,
  activo       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE receta (                            -- NUEVA
  id_receta         INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cliente        INT NOT NULL REFERENCES cliente,
  numero_receta     VARCHAR(30)  NOT NULL,
  nombre_medico     VARCHAR(120) NOT NULL,
  colegiado_medico  VARCHAR(20)  NOT NULL,
  fecha_emision     DATE NOT NULL
);

-- ===== Pedidos, pagos y reservas =====
CREATE TABLE pasarela (
  id_pasarela   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  nombre        VARCHAR(60)  NOT NULL,
  comision_pct  NUMERIC(5,2) NOT NULL
);

CREATE TABLE pedido (
  id_pedido    INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cliente   INT NOT NULL REFERENCES cliente,
  id_sucursal  INT NOT NULL REFERENCES sucursal,
  id_empleado  INT REFERENCES empleado,   -- NULL cuando el pedido viene de la App
  canal        VARCHAR(20) NOT NULL,      -- APP, POS, CALL_CENTER
  estado       VARCHAR(20) NOT NULL DEFAULT 'PENDIENTE',
  fecha        TIMESTAMP   NOT NULL DEFAULT now()
);

CREATE TABLE promocion (                         -- NUEVA
  id_promocion          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_lote               INT NOT NULL REFERENCES lote,
  porcentaje_descuento  NUMERIC(5,2) NOT NULL,
  fecha_inicio          DATE NOT NULL,
  fecha_fin             DATE NOT NULL,
  activa                BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE detalle_pedido (
  id_detalle          INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pedido           INT NOT NULL REFERENCES pedido,
  id_lote             INT NOT NULL REFERENCES lote,
  id_receta           INT REFERENCES receta,      -- obligatoria si el producto la requiere
  id_promocion        INT REFERENCES promocion,   -- NULL si no hubo promoción
  cantidad            INT NOT NULL,
  precio_unitario     NUMERIC(12,2) NOT NULL,
  descuento_unitario  NUMERIC(12,2) NOT NULL DEFAULT 0
);

CREATE TABLE pago (
  id_pago           INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pedido         INT NOT NULL REFERENCES pedido,
  id_pasarela       INT NOT NULL REFERENCES pasarela,
  monto_bruto       NUMERIC(12,2) NOT NULL,
  descuento_seguro  NUMERIC(12,2) NOT NULL DEFAULT 0,
  descuento_puntos  NUMERIC(12,2) NOT NULL DEFAULT 0,
  comision          NUMERIC(12,2) NOT NULL DEFAULT 0,
  monto_neto        NUMERIC(12,2) NOT NULL,
  fecha             TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE intento_pago (                      -- NUEVA
  id_intento        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_pedido         INT NOT NULL REFERENCES pedido,
  id_pasarela       INT NOT NULL REFERENCES pasarela,
  monto             NUMERIC(12,2) NOT NULL,
  estado            VARCHAR(20) NOT NULL,   -- APROBADO, RECHAZADO, ERROR
  codigo_respuesta  VARCHAR(10),
  mensaje           VARCHAR(200),
  fecha             TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE reserva (
  id_reserva   INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cliente   INT NOT NULL REFERENCES cliente,
  id_lote      INT NOT NULL,
  id_sucursal  INT NOT NULL,
  cantidad     INT NOT NULL,
  creada_en    TIMESTAMP NOT NULL DEFAULT now(),
  expira_en    TIMESTAMP NOT NULL,
  estado       VARCHAR(20) NOT NULL DEFAULT 'ACTIVA',
  FOREIGN KEY (id_lote, id_sucursal) REFERENCES inventario_lote
);

CREATE TABLE movimiento_puntos (
  id_movimiento  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_cliente     INT NOT NULL REFERENCES cliente,
  id_pedido      INT REFERENCES pedido,
  puntos         INT NOT NULL,           -- positivo gana, negativo canjea
  fecha          TIMESTAMP NOT NULL DEFAULT now()
);

-- ===== Trazabilidad y control =====
CREATE TABLE movimiento_inventario (             -- NUEVA (kardex por lote)
  id_movimiento  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_lote        INT NOT NULL,
  id_sucursal    INT NOT NULL,
  tipo           VARCHAR(20) NOT NULL,   -- ENTRADA, VENTA, AJUSTE, MERMA, TRASLADO_SALIDA, TRASLADO_ENTRADA, DEVOLUCION
  cantidad       INT NOT NULL,           -- positivo entra, negativo sale
  id_pedido      INT REFERENCES pedido,
  id_empleado    INT REFERENCES empleado,
  observacion    VARCHAR(200),
  fecha          TIMESTAMP NOT NULL DEFAULT now(),
  FOREIGN KEY (id_lote, id_sucursal) REFERENCES inventario_lote
);

CREATE TABLE devolucion_laboratorio (            -- NUEVA
  id_devolucion  INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  id_lote        INT NOT NULL,
  id_sucursal    INT NOT NULL,
  cantidad       INT NOT NULL,
  motivo         VARCHAR(20) NOT NULL,   -- PROXIMO_A_VENCER, VENCIDO, DANADO, RETIRO_SANITARIO
  estado         VARCHAR(20) NOT NULL DEFAULT 'SOLICITADA',
  monto_credito  NUMERIC(12,2) NOT NULL DEFAULT 0,
  fecha          DATE NOT NULL DEFAULT CURRENT_DATE,
  FOREIGN KEY (id_lote, id_sucursal) REFERENCES inventario_lote
);

CREATE TABLE auditoria (                         -- NUEVA (la llenan triggers)
  id_auditoria    BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  tabla_afectada  VARCHAR(60) NOT NULL,
  operacion       VARCHAR(10) NOT NULL,   -- INSERT, UPDATE, DELETE
  valor_anterior  JSONB,
  valor_nuevo     JSONB,
  usuario         VARCHAR(60) NOT NULL DEFAULT current_user,
  fecha           TIMESTAMP   NOT NULL DEFAULT now()
);


---------------------------------------------------------------------------



ALTER TABLE sucursal        ADD CHECK (tipo IN ('FARMACIA','BODEGA')),
                            ADD UNIQUE (nombre);
ALTER TABLE producto        ADD UNIQUE (codigo),
                            ADD CHECK (precio_venta > 0);
ALTER TABLE lote            ADD UNIQUE (id_producto, numero_lote),
                            ADD CHECK (fecha_vencimiento > fecha_fabricacion);
ALTER TABLE inventario_lote ADD CHECK (existencia >= 0),
                            ADD CHECK (reservada >= 0 AND reservada <= existencia);
ALTER TABLE aseguradora     ADD CHECK (porcentaje_cobertura BETWEEN 0 AND 100);
ALTER TABLE cliente         ADD UNIQUE (email),
                            ADD CHECK (puntos >= 0);
ALTER TABLE empleado        ADD CHECK (puesto IN ('DEPENDIENTE','CAJERO','AGENTE_CALL','BODEGUERO','ADMIN'));
ALTER TABLE receta          ADD UNIQUE (numero_receta),
                            ADD CHECK (fecha_emision <= CURRENT_DATE);
ALTER TABLE pasarela        ADD UNIQUE (nombre),
                            ADD CHECK (comision_pct BETWEEN 0 AND 100);
ALTER TABLE pedido          ADD CHECK (canal IN ('APP','POS','CALL_CENTER')),
                            ADD CHECK (estado IN ('PENDIENTE','PAGADO','ENTREGADO','ANULADO'));
ALTER TABLE promocion       ADD CHECK (porcentaje_descuento > 0 AND porcentaje_descuento <= 100),
                            ADD CHECK (fecha_fin >= fecha_inicio);
ALTER TABLE detalle_pedido  ADD CHECK (cantidad > 0),
                            ADD CHECK (descuento_unitario >= 0 AND descuento_unitario <= precio_unitario);
ALTER TABLE pago            ADD UNIQUE (id_pedido),
                            ADD CHECK (monto_bruto >= 0 AND monto_neto >= 0);
ALTER TABLE intento_pago    ADD CHECK (estado IN ('APROBADO','RECHAZADO','ERROR')),
                            ADD CHECK (monto >= 0);
ALTER TABLE reserva         ADD CHECK (cantidad > 0),
                            ADD CHECK (expira_en > creada_en),
                            ADD CHECK (estado IN ('ACTIVA','CONFIRMADA','EXPIRADA'));
ALTER TABLE movimiento_inventario
                            ADD CHECK (tipo IN ('ENTRADA','VENTA','AJUSTE','MERMA','TRASLADO_SALIDA','TRASLADO_ENTRADA','DEVOLUCION')),
                            ADD CHECK (cantidad <> 0);
ALTER TABLE devolucion_laboratorio
                            ADD CHECK (cantidad > 0),
                            ADD CHECK (motivo IN ('PROXIMO_A_VENCER','VENCIDO','DANADO','RETIRO_SANITARIO')),
                            ADD CHECK (estado IN ('SOLICITADA','ENVIADA','ACREDITADA')),
                            ADD CHECK (monto_credito >= 0);
ALTER TABLE auditoria       ADD CHECK (operacion IN ('INSERT','UPDATE','DELETE'));

-- Índices: por aquí buscan el checkout FEFO, los reportes y el kardex
CREATE INDEX idx_lote_producto_venc ON lote (id_producto, fecha_vencimiento);
CREATE INDEX idx_inv_sucursal       ON inventario_lote (id_sucursal);
CREATE INDEX idx_pedido_fecha       ON pedido (fecha);
CREATE INDEX idx_reserva_expira     ON reserva (expira_en) WHERE estado = 'ACTIVA';
CREATE INDEX idx_movinv_lote        ON movimiento_inventario (id_lote, id_sucursal, fecha);
CREATE INDEX idx_promo_lote         ON promocion (id_lote) WHERE activa;
CREATE INDEX idx_auditoria_tabla    ON auditoria (tabla_afectada, fecha);

-- Auditoría automática: un solo trigger genérico para varias tablas
CREATE OR REPLACE FUNCTION fn_auditoria() RETURNS trigger AS $$
BEGIN
  INSERT INTO auditoria (tabla_afectada, operacion, valor_anterior, valor_nuevo)
  VALUES (TG_TABLE_NAME, TG_OP,
          CASE WHEN TG_OP IN ('UPDATE','DELETE') THEN to_jsonb(OLD) END,
          CASE WHEN TG_OP IN ('INSERT','UPDATE') THEN to_jsonb(NEW) END);
  RETURN COALESCE(NEW, OLD);
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_aud_inventario AFTER UPDATE OR DELETE ON inventario_lote
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();
CREATE TRIGGER trg_aud_producto   AFTER UPDATE OR DELETE ON producto
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();
CREATE TRIGGER trg_aud_pago       AFTER INSERT OR UPDATE OR DELETE ON pago
  FOR EACH ROW EXECUTE FUNCTION fn_auditoria();























