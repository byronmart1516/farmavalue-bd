SET search_path TO farmavalue;

INSERT INTO sucursal (nombre, tipo, direccion) VALUES
 ('FarmaValue Zona 10',               'FARMACIA', 'Zona 10, Ciudad de Guatemala'),
 ('FarmaValue Cayalá',                'FARMACIA', 'Paseo Cayalá, Zona 16'),
 ('Bodega Central de Distribución',  'BODEGA',   'Zona 12, Ciudad de Guatemala');

INSERT INTO pasarela (nombre, comision_pct) VALUES
 ('VisaNet', 3.50), ('BAC Credomatic', 3.25), ('Efectivo/POS contra entrega', 0.00);

INSERT INTO aseguradora (nombre, porcentaje_cobertura) VALUES
 ('Seguros G&T', 20.00), ('Seguros El Roble', 15.00), ('Pan-American Life', 25.00);

INSERT INTO categoria (nombre) VALUES
 ('Antibióticos'), ('Analgésicos'), ('Antialérgicos'), ('Gastrointestinal'),
 ('Crónicos'), ('Respiratorio'), ('Vitaminas'), ('Cuidado personal');

INSERT INTO laboratorio (nombre) VALUES
 ('Bayer'), ('Pfizer'), ('Genfar'), ('Infasa'), ('Abbott');

-- 60 clientes de prueba; 1 de cada 3 tiene aseguradora
INSERT INTO cliente (nombre, nit, telefono, email, id_aseguradora, puntos)
SELECT 'Cliente ' || n,
       (1000000 + n)::text,
       '5' || lpad((n * 7919 % 10000000)::text, 7, '0'),
       'cliente' || n || '@correo.com',
       CASE WHEN n % 3 = 0 THEN (n / 3) % 3 + 1 END,
       (n * 37) % 500
FROM generate_series(1, 60) AS n;

-- 12 empleados: mostrador, caja y call center en las farmacias; bodegueros en la bodega
INSERT INTO empleado (nombre, puesto, id_sucursal) VALUES
 ('Ana López',        'DEPENDIENTE', 1), ('Carlos Pérez',   'CAJERO',      1),
 ('María García',     'AGENTE_CALL', 1), ('José Hernández', 'ADMIN',       1),
 ('Lucía Morales',    'DEPENDIENTE', 2), ('Diego Ramírez',  'CAJERO',      2),
 ('Sofía Castillo',   'AGENTE_CALL', 2), ('Andrés Flores',  'ADMIN',       2),
 ('Pedro Méndez',     'BODEGUERO',   3), ('Karla Ruiz',     'BODEGUERO',   3),
 ('Luis Orellana',    'BODEGUERO',   3), ('Gabriela Solís', 'ADMIN',       3);





----------------------------------------------------------------------------------


INSERT INTO producto (codigo, nombre, id_categoria, id_laboratorio, requiere_receta, precio_venta) VALUES
 ('P001','Amoxicilina 500 mg x21 cápsulas',        1, 3, TRUE,   65.00),
 ('P002','Azitromicina 500 mg x3 tabletas',         1, 2, TRUE,   98.50),
 ('P003','Ciprofloxacina 500 mg x10 tabletas',      1, 4, TRUE,   72.00),
 ('P004','Amoxicilina susp. 250 mg/5 ml 60 ml',     1, 3, TRUE,   48.75),
 ('P005','Acetaminofén 500 mg x100 tabletas',       2, 4, FALSE,  45.00),
 ('P006','Ibuprofeno 400 mg x50 tabletas',          2, 5, FALSE,  58.00),
 ('P007','Diclofenaco gel 1% 60 g',                 2, 1, FALSE,  62.50),
 ('P008','Loratadina 10 mg x10 tabletas',           3, 1, FALSE,  35.00),
 ('P009','Cetirizina 10 mg x10 tabletas',           3, 3, FALSE,  32.00),
 ('P010','Omeprazol 20 mg x14 cápsulas',            4, 4, FALSE,  55.00),
 ('P011','Suero oral 500 ml',                        4, 5, FALSE,  14.50),
 ('P012','Metformina 850 mg x30 tabletas',          5, 2, TRUE,   40.00),
 ('P013','Losartán 50 mg x30 tabletas',             5, 3, TRUE,   75.00),
 ('P014','Atorvastatina 20 mg x30 tabletas',        5, 2, TRUE,  120.00),
 ('P015','Insulina NPH 100 UI/ml 10 ml',            5, 5, TRUE,  185.00),
 ('P016','Salbutamol inhalador 100 mcg',            6, 3, TRUE,   68.00),
 ('P017','Jarabe para la tos 120 ml',               6, 1, FALSE,  52.00),
 ('P018','Vitamina C 1 g x10 efervescentes',        7, 1, FALSE,  38.00),
 ('P019','Ácido fólico 5 mg x30 tabletas',          7, 4, FALSE,  25.00),
 ('P020','Alcohol en gel 70% 250 ml',               8, 4, FALSE,  22.00);

-- 3 lotes por producto con vencimientos repartidos entre 10 y ~400 días
INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento)
SELECT p.id_producto,
       'L' || p.codigo || '-' || k,
       CURRENT_DATE - 365,
       CURRENT_DATE + ((p.id_producto * 17 + k * 97) % 400 + 10)
FROM producto p CROSS JOIN generate_series(1, 3) AS k;

-- Cada lote en las 3 sucursales con existencias entre 5 y 60
INSERT INTO inventario_lote (id_lote, id_sucursal, existencia)
SELECT l.id_lote, s.id_sucursal, 5 + (l.id_lote * 13 + s.id_sucursal * 7) % 56
FROM lote l CROSS JOIN sucursal s;

-- Lote crítico para la prueba de concurrencia: 1 sola caja en Zona 10
INSERT INTO lote (id_producto, numero_lote, fecha_fabricacion, fecha_vencimiento)
VALUES (2, 'LCRIT-001', CURRENT_DATE - 200, CURRENT_DATE + 15);
INSERT INTO inventario_lote (id_lote, id_sucursal, existencia)
SELECT id_lote, 1, 1 FROM lote WHERE numero_lote = 'LCRIT-001';

-- Kardex: cada existencia inicial queda registrada como una ENTRADA
INSERT INTO movimiento_inventario (id_lote, id_sucursal, tipo, cantidad, observacion, fecha)
SELECT id_lote, id_sucursal, 'ENTRADA', existencia, 'Inventario inicial', now() - interval '100 days'
FROM inventario_lote;

-- 40 recetas para clientes de prueba (se usan en el poblado al vender productos con receta)
INSERT INTO receta (id_cliente, numero_receta, nombre_medico, colegiado_medico, fecha_emision)
SELECT 1 + (n * 7) % 60,
       'RX-' || lpad(n::text, 5, '0'),
       (ARRAY['Dr. Roberto Juárez','Dra. Elena Barrios','Dr. Mario Cifuentes','Dra. Paola Monzón'])[1 + n % 4],
       (10000 + n * 13)::text,
       CURRENT_DATE - (n % 60)
FROM generate_series(1, 40) AS n;

-- Promociones automáticas: 25% de descuento en lotes que vencen en 30 días o menos
INSERT INTO promocion (id_lote, porcentaje_descuento, fecha_inicio, fecha_fin)
SELECT id_lote, 25.00, CURRENT_DATE, fecha_vencimiento - 1
FROM lote
WHERE fecha_vencimiento <= CURRENT_DATE + 30
  AND numero_lote <> 'LCRIT-001';

-- Devoluciones al laboratorio: lotes de la bodega que vencen en 45 días o menos
INSERT INTO devolucion_laboratorio (id_lote, id_sucursal, cantidad, motivo, estado, monto_credito)
SELECT il.id_lote, il.id_sucursal, il.existencia, 'PROXIMO_A_VENCER', 'SOLICITADA',
       ROUND(il.existencia * p.precio_venta * 0.60, 2)
FROM inventario_lote il
JOIN lote l     ON l.id_lote = il.id_lote
JOIN producto p ON p.id_producto = l.id_producto
WHERE il.id_sucursal = 3
  AND l.fecha_vencimiento <= CURRENT_DATE + 45;











