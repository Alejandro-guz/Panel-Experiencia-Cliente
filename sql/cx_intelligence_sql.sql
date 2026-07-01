-- ============================================================
--  CX INTELLIGENCE · BANCO DAVIVIENDA
--  Proyecto: Analítica de Experiencia del Cliente
--  Autor: [Tu nombre] | Postulación Analista BI CX
--  Motor: SQL Server / PostgreSQL compatible
-- ============================================================


-- ============================================================
-- SECCIÓN 1: MODELO DE DATOS (DDL)
-- ============================================================

-- Dimensión de clientes
CREATE TABLE dim_cliente (
    cliente_id      INT PRIMARY KEY,
    segmento        VARCHAR(30),   -- Premium, Nómina, Personas, Pymes, Digital
    antiguedad_anos DECIMAL(5,2),
    canal_principal VARCHAR(20),   -- App, Web, Call Center, Sucursal
    region          VARCHAR(30),
    activo          BIT DEFAULT 1
);

-- Dimensión de canales
CREATE TABLE dim_canal (
    canal_id   INT PRIMARY KEY,
    canal_nome VARCHAR(30),
    tipo       VARCHAR(20)    -- Digital, Presencial, Telefónico
);

-- Dimensión de tiempo
CREATE TABLE dim_tiempo (
    fecha_id   INT PRIMARY KEY,  -- formato YYYYMMDD
    fecha      DATE,
    anio       INT,
    mes        INT,
    trimestre  INT,
    semana_iso INT,
    dia_semana VARCHAR(12)
);

-- Tabla de encuestas NPS
CREATE TABLE fact_nps (
    encuesta_id  BIGINT PRIMARY KEY,
    cliente_id   INT REFERENCES dim_cliente(cliente_id),
    canal_id     INT REFERENCES dim_canal(canal_id),
    fecha_id     INT REFERENCES dim_tiempo(fecha_id),
    score_nps    TINYINT CHECK (score_nps BETWEEN 0 AND 10),
    categoria    AS (CASE
                        WHEN score_nps >= 9 THEN 'Promotor'
                        WHEN score_nps >= 7 THEN 'Pasivo'
                        ELSE 'Detractor'
                    END) PERSISTED,
    comentario   NVARCHAR(500),
    producto     VARCHAR(50),
    fecha_envio  DATETIME2
);

-- Tabla de encuestas CSAT
CREATE TABLE fact_csat (
    csat_id     BIGINT PRIMARY KEY,
    cliente_id  INT REFERENCES dim_cliente(cliente_id),
    canal_id    INT REFERENCES dim_canal(canal_id),
    fecha_id    INT REFERENCES dim_tiempo(fecha_id),
    score_csat  TINYINT CHECK (score_csat BETWEEN 1 AND 5),
    motivo      VARCHAR(60),
    resuelto    BIT,
    tiempo_min  INT   -- tiempo de resolución en minutos
);

-- Tabla de interacciones (Call Center + todos los canales)
CREATE TABLE fact_interaccion (
    interaccion_id BIGINT PRIMARY KEY,
    cliente_id     INT REFERENCES dim_cliente(cliente_id),
    canal_id       INT REFERENCES dim_canal(canal_id),
    fecha_id       INT REFERENCES dim_tiempo(fecha_id),
    motivo         VARCHAR(80),
    resuelto_1ra   BIT,        -- FCR: resuelto en primera llamada/contacto
    duracion_seg   INT,
    agente_id      INT,
    escalado       BIT DEFAULT 0
);


-- ============================================================
-- SECCIÓN 2: ETL · CARGA Y LIMPIEZA DE DATOS
-- ============================================================

-- Stored procedure de carga incremental NPS desde fuente raw
CREATE OR ALTER PROCEDURE sp_etl_cargar_nps
    @fecha_desde DATE,
    @fecha_hasta DATE
AS
BEGIN
    SET NOCOUNT ON;

    -- Eliminar duplicados antes de insertar (control de calidad)
    WITH duplicados AS (
        SELECT encuesta_id,
               ROW_NUMBER() OVER (
                   PARTITION BY cliente_id, fecha_id, canal_id
                   ORDER BY fecha_envio DESC
               ) AS rn
        FROM fact_nps
        WHERE fecha_envio BETWEEN @fecha_desde AND @fecha_hasta
    )
    DELETE FROM duplicados WHERE rn > 1;

    -- Insertar encuestas nuevas desde staging
    INSERT INTO fact_nps (encuesta_id, cliente_id, canal_id, fecha_id,
                          score_nps, comentario, producto, fecha_envio)
    SELECT
        s.encuesta_id,
        c.cliente_id,
        ch.canal_id,
        CAST(FORMAT(s.fecha_respuesta, 'yyyyMMdd') AS INT),
        s.calificacion_nps,
        TRIM(s.comentario_texto),
        s.producto_relacionado,
        s.fecha_respuesta
    FROM stg_encuestas_nps s
    INNER JOIN dim_cliente  c  ON s.num_cliente = c.cliente_id
    INNER JOIN dim_canal    ch ON s.canal       = ch.canal_nome
    WHERE s.fecha_respuesta BETWEEN @fecha_desde AND @fecha_hasta
      AND s.calificacion_nps BETWEEN 0 AND 10     -- validación de rango
      AND s.encuesta_id NOT IN (SELECT encuesta_id FROM fact_nps);

    -- Log de carga
    INSERT INTO log_etl (proceso, fecha_ejecucion, registros_insertados)
    SELECT 'ETL_NPS', GETDATE(), @@ROWCOUNT;
END;


-- ============================================================
-- SECCIÓN 3: INDICADORES CLAVE (QUERIES ANALÍTICOS)
-- ============================================================

-- ── 3.1 NPS Mensual por Canal ─────────────────────────────
SELECT
    t.anio,
    t.mes,
    ch.canal_nome,
    COUNT(*)                                        AS total_encuestas,
    SUM(CASE WHEN f.categoria = 'Promotor'  THEN 1 ELSE 0 END) AS promotores,
    SUM(CASE WHEN f.categoria = 'Detractor' THEN 1 ELSE 0 END) AS detractores,
    ROUND(
        100.0 * SUM(CASE WHEN f.categoria = 'Promotor'  THEN 1 ELSE 0 END) / COUNT(*) -
        100.0 * SUM(CASE WHEN f.categoria = 'Detractor' THEN 1 ELSE 0 END) / COUNT(*),
    1)                                              AS nps_score
FROM fact_nps      f
JOIN dim_tiempo    t  ON f.fecha_id  = t.fecha_id
JOIN dim_canal     ch ON f.canal_id  = ch.canal_id
WHERE t.anio = YEAR(GETDATE())
GROUP BY t.anio, t.mes, ch.canal_nome
ORDER BY t.anio, t.mes, ch.canal_nome;


-- ── 3.2 CSAT Promedio por Segmento y Motivo ──────────────
SELECT
    c.segmento,
    cs.motivo,
    COUNT(*)                                    AS total_respuestas,
    ROUND(AVG(CAST(cs.score_csat AS FLOAT)), 2) AS csat_promedio,
    ROUND(100.0 * AVG(CAST(cs.score_csat AS FLOAT)) / 5, 1) AS csat_pct,
    ROUND(AVG(CAST(cs.tiempo_min AS FLOAT)), 0) AS tiempo_resolucion_avg_min
FROM fact_csat  cs
JOIN dim_cliente c  ON cs.cliente_id = c.cliente_id
JOIN dim_tiempo  t  ON cs.fecha_id   = t.fecha_id
WHERE t.anio = YEAR(GETDATE())
GROUP BY c.segmento, cs.motivo
HAVING COUNT(*) >= 30   -- mínimo estadístico
ORDER BY c.segmento, csat_promedio DESC;


-- ── 3.3 FCR (First Contact Resolution) por Canal ─────────
SELECT
    t.anio,
    t.mes,
    ch.canal_nome,
    COUNT(*)                                                        AS total_interacciones,
    SUM(CAST(i.resuelto_1ra AS INT))                               AS resueltas_1ra,
    ROUND(100.0 * SUM(CAST(i.resuelto_1ra AS INT)) / COUNT(*), 1) AS fcr_pct,
    ROUND(AVG(CAST(i.duracion_seg AS FLOAT)) / 60.0, 1)           AS duracion_avg_min
FROM fact_interaccion i
JOIN dim_tiempo       t  ON i.fecha_id  = t.fecha_id
JOIN dim_canal        ch ON i.canal_id  = ch.canal_id
WHERE t.anio = YEAR(GETDATE())
GROUP BY t.anio, t.mes, ch.canal_nome
ORDER BY t.mes, fcr_pct DESC;


-- ── 3.4 Dashboard ejecutivo consolidado (vista mensual) ──
WITH metricas_mes AS (
    SELECT
        t.anio,
        t.mes,

        -- NPS
        ROUND(
            100.0 * SUM(CASE WHEN n.categoria = 'Promotor'  THEN 1 ELSE 0 END) / COUNT(DISTINCT n.encuesta_id) -
            100.0 * SUM(CASE WHEN n.categoria = 'Detractor' THEN 1 ELSE 0 END) / COUNT(DISTINCT n.encuesta_id),
        1) AS nps_score,

        -- CSAT
        ROUND(100.0 * AVG(CAST(cs.score_csat AS FLOAT)) / 5, 1) AS csat_pct,

        -- FCR
        ROUND(100.0 * SUM(CAST(i.resuelto_1ra AS INT)) / COUNT(DISTINCT i.interaccion_id), 1) AS fcr_pct,

        COUNT(DISTINCT i.interaccion_id) AS vol_interacciones

    FROM dim_tiempo t
    LEFT JOIN fact_nps          n  ON t.fecha_id = n.fecha_id
    LEFT JOIN fact_csat         cs ON t.fecha_id = cs.fecha_id
    LEFT JOIN fact_interaccion  i  ON t.fecha_id = i.fecha_id
    WHERE t.anio = YEAR(GETDATE())
    GROUP BY t.anio, t.mes
)
SELECT
    anio,
    mes,
    nps_score,
    csat_pct,
    fcr_pct,
    vol_interacciones,
    -- Variación mes a mes
    nps_score  - LAG(nps_score)  OVER (ORDER BY anio, mes) AS nps_delta,
    csat_pct   - LAG(csat_pct)   OVER (ORDER BY anio, mes) AS csat_delta,
    fcr_pct    - LAG(fcr_pct)    OVER (ORDER BY anio, mes) AS fcr_delta
FROM metricas_mes
ORDER BY anio, mes;


-- ── 3.5 Análisis de Drivers de Insatisfacción ────────────
-- Identifica qué motivos generan los NPS más bajos (priorización de mejoras)
SELECT
    i.motivo,
    COUNT(DISTINCT n.encuesta_id)            AS encuestas,
    ROUND(AVG(CAST(n.score_nps AS FLOAT)),1) AS nps_avg,
    SUM(CASE WHEN n.categoria='Detractor' THEN 1 ELSE 0 END) AS detractores,
    ROUND(
        100.0 * SUM(CASE WHEN n.categoria='Detractor' THEN 1 ELSE 0 END)
              / NULLIF(COUNT(*),0),
    1)                                       AS pct_detractores,
    -- Score de prioridad: volumen × severidad
    ROUND(
        COUNT(*) * (1 - AVG(CAST(n.score_nps AS FLOAT)) / 10.0),
    0)                                       AS prioridad_score
FROM fact_interaccion i
JOIN dim_cliente      c  ON i.cliente_id = c.cliente_id
JOIN fact_nps         n  ON i.cliente_id = n.cliente_id
                         AND i.fecha_id  = n.fecha_id
JOIN dim_tiempo       t  ON i.fecha_id   = t.fecha_id
WHERE t.anio = YEAR(GETDATE())
  AND t.mes  >= MONTH(GETDATE()) - 3   -- últimos 3 meses
GROUP BY i.motivo
HAVING COUNT(*) >= 50
ORDER BY prioridad_score DESC;


-- ── 3.6 Segmentación de clientes por riesgo de churn ────
-- Clientes con señales de insatisfacción sostenida
WITH historial AS (
    SELECT
        n.cliente_id,
        COUNT(*)                                        AS encuestas_6m,
        AVG(CAST(n.score_nps AS FLOAT))                AS nps_avg_6m,
        MIN(n.score_nps)                               AS nps_min,
        SUM(CASE WHEN n.categoria='Detractor' THEN 1 ELSE 0 END) AS detractores_6m,
        MAX(t.fecha)                                   AS ultima_encuesta
    FROM fact_nps   n
    JOIN dim_tiempo t ON n.fecha_id = t.fecha_id
    WHERE t.fecha >= DATEADD(MONTH, -6, GETDATE())
    GROUP BY n.cliente_id
)
SELECT
    h.cliente_id,
    c.segmento,
    c.canal_principal,
    h.nps_avg_6m,
    h.detractores_6m,
    h.encuestas_6m,
    h.ultima_encuesta,
    CASE
        WHEN h.nps_avg_6m < 4 AND h.detractores_6m >= 2 THEN 'Alto riesgo'
        WHEN h.nps_avg_6m < 6 OR  h.detractores_6m >= 1 THEN 'Riesgo medio'
        ELSE 'Bajo riesgo'
    END AS nivel_riesgo_churn
FROM historial    h
JOIN dim_cliente  c ON h.cliente_id = c.cliente_id
WHERE h.encuestas_6m >= 2
ORDER BY h.nps_avg_6m ASC, h.detractores_6m DESC;


-- ============================================================
-- SECCIÓN 4: VISTAS PARA POWER BI
-- ============================================================

-- Vista principal para el dashboard ejecutivo
CREATE OR REPLACE VIEW vw_cx_dashboard AS
SELECT
    t.anio,
    t.mes,
    t.trimestre,
    ch.canal_nome          AS canal,
    c.segmento,
    n.categoria            AS clasificacion_nps,
    n.score_nps,
    cs.score_csat,
    CAST(cs.score_csat AS FLOAT) / 5 * 100  AS csat_pct,
    i.resuelto_1ra         AS fcr_flag,
    i.motivo               AS motivo_contacto,
    i.duracion_seg         AS duracion_contacto_seg
FROM dim_tiempo       t
LEFT JOIN fact_nps          n  ON t.fecha_id  = n.fecha_id
LEFT JOIN fact_csat         cs ON t.fecha_id  = cs.fecha_id
                              AND n.cliente_id = cs.cliente_id
LEFT JOIN fact_interaccion  i  ON t.fecha_id  = i.fecha_id
                              AND n.cliente_id = i.cliente_id
LEFT JOIN dim_canal         ch ON n.canal_id  = ch.canal_id
LEFT JOIN dim_cliente        c ON n.cliente_id = c.cliente_id;


-- Vista de alertas operativas (para panel de monitoreo)
CREATE OR REPLACE VIEW vw_alertas_cx AS
WITH base AS (
    SELECT
        ch.canal_nome,
        ROUND(
            100.0 * SUM(CASE WHEN n.categoria='Promotor' THEN 1 ELSE 0 END)/COUNT(*) -
            100.0 * SUM(CASE WHEN n.categoria='Detractor'THEN 1 ELSE 0 END)/COUNT(*),
        1) AS nps_mes,
        ROUND(100.0 * AVG(CAST(cs.score_csat AS FLOAT))/5, 1) AS csat_mes,
        ROUND(100.0 * SUM(CAST(i.resuelto_1ra AS INT))/NULLIF(COUNT(i.interaccion_id),0),1) AS fcr_mes
    FROM dim_tiempo       t
    JOIN fact_nps          n  ON t.fecha_id = n.fecha_id
    JOIN fact_csat         cs ON t.fecha_id = cs.fecha_id AND n.cliente_id = cs.cliente_id
    JOIN fact_interaccion  i  ON t.fecha_id = i.fecha_id  AND n.cliente_id = i.cliente_id
    JOIN dim_canal         ch ON n.canal_id = ch.canal_id
    WHERE t.anio = YEAR(GETDATE()) AND t.mes = MONTH(GETDATE())
    GROUP BY ch.canal_nome
)
SELECT
    canal_nome,
    nps_mes,
    csat_mes,
    fcr_mes,
    CASE
        WHEN nps_mes < 30 OR csat_mes < 65 THEN 'Crítico'
        WHEN nps_mes < 50 OR csat_mes < 75 THEN 'Revisar'
        ELSE 'Óptimo'
    END AS estado_alerta
FROM base;


-- ============================================================
-- SECCIÓN 5: ÍNDICES DE PERFORMANCE
-- ============================================================

CREATE INDEX idx_nps_fecha_canal
    ON fact_nps(fecha_id, canal_id) INCLUDE (score_nps, categoria);

CREATE INDEX idx_csat_fecha_seg
    ON fact_csat(fecha_id, cliente_id) INCLUDE (score_csat, motivo);

CREATE INDEX idx_interaccion_fecha
    ON fact_interaccion(fecha_id, canal_id) INCLUDE (resuelto_1ra, motivo);

CREATE INDEX idx_tiempo_anio_mes
    ON dim_tiempo(anio, mes) INCLUDE (trimestre, fecha);


-- ============================================================
-- FIN DEL SCRIPT
-- Davivienda CX Intelligence · v1.0
-- ============================================================
