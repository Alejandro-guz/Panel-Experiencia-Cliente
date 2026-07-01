# Guía: armar el .pbix en Power BI Desktop

Esta guía toma ~10-15 minutos. Al final tendrás un archivo `.pbix` real para subir a `powerbi/cx_intelligence.pbix`.

Requisito: [Power BI Desktop](https://www.microsoft.com/en-us/power-platform/products/power-bi/desktop) (gratis, solo Windows).

---

## 1. Cargar los datos

`Inicio → Obtener datos → Texto/CSV`

Importa los 6 archivos de la carpeta `data/`, uno por uno:

- `dim_cliente.csv`
- `dim_canal.csv`
- `dim_tiempo.csv`
- `fact_nps.csv`
- `fact_csat.csv`
- `fact_interaccion.csv`

En cada uno, click **Transformar datos** (no "Cargar" directo) para verificar tipos de columna antes de cargar. Asegúrate que:
- `fecha_id` sea **Número entero** en todas las tablas
- `fecha` en `dim_tiempo` sea tipo **Fecha**
- `score_nps`, `score_csat` sean **Número entero**

Click **Cerrar y aplicar**.

---

## 2. Crear relaciones (Modelo de datos)

Ve a la vista **Modelo** (ícono de tablas conectadas, panel izquierdo).

Arrastra para crear estas relaciones (todas 1 a muchos, dirección única):

| Desde | Campo | Hacia | Campo |
|---|---|---|---|
| `dim_tiempo` | `fecha_id` | `fact_nps` | `fecha_id` |
| `dim_tiempo` | `fecha_id` | `fact_csat` | `fecha_id` |
| `dim_tiempo` | `fecha_id` | `fact_interaccion` | `fecha_id` |
| `dim_canal` | `canal_id` | `fact_nps` | `canal_id` |
| `dim_canal` | `canal_id` | `fact_csat` | `canal_id` |
| `dim_canal` | `canal_id` | `fact_interaccion` | `canal_id` |
| `dim_cliente` | `cliente_id` | `fact_nps` | `cliente_id` |
| `dim_cliente` | `cliente_id` | `fact_csat` | `cliente_id` |
| `dim_cliente` | `cliente_id` | `fact_interaccion` | `cliente_id` |

Esto te da el modelo estrella clásico: 3 dimensiones en el centro, 3 tablas de hechos alrededor.

---

## 3. Crear columna calculada de categoría NPS

En `fact_nps`, click derecho → **Nueva columna**:

```dax
categoria = 
SWITCH(
    TRUE(),
    fact_nps[score_nps] >= 9, "Promotor",
    fact_nps[score_nps] >= 7, "Pasivo",
    "Detractor"
)
```

---

## 4. Crear las medidas DAX

En cualquier tabla (recomendado: crear una tabla vacía llamada `_Medidas` solo para organizarlas), click derecho → **Nueva medida**, y pega cada una:

```dax
NPS Score = 
VAR promotores = COUNTROWS(FILTER(fact_nps, fact_nps[categoria] = "Promotor"))
VAR detractores = COUNTROWS(FILTER(fact_nps, fact_nps[categoria] = "Detractor"))
VAR total = COUNTROWS(fact_nps)
RETURN DIVIDE(promotores - detractores, total) * 100
```

```dax
CSAT % = AVERAGEX(fact_csat, DIVIDE(fact_csat[score_csat], 5)) * 100
```

```dax
FCR % = 
DIVIDE(
    COUNTROWS(FILTER(fact_interaccion, fact_interaccion[resuelto_1ra] = 1)),
    COUNTROWS(fact_interaccion)
) * 100
```

```dax
Total Tickets = COUNTROWS(fact_interaccion)
```

(El delta mes a mes requiere marcar `dim_tiempo[fecha]` como tabla de fechas: click en la tabla → pestaña **Herramientas de tabla** → **Marcar como tabla de fechas**.)

```dax
NPS Delta MoM = 
VAR mesAnterior = CALCULATE([NPS Score], DATEADD(dim_tiempo[fecha], -1, MONTH))
RETURN [NPS Score] - mesAnterior
```

---

## 5. Armar las visualizaciones

Vista **Informe**, arma 4 tarjetas KPI arriba (`Tarjeta` visual) con: `NPS Score`, `CSAT %`, `FCR %`, `Total Tickets`.

Debajo, agrega:
- **Gráfico de líneas**: eje X = `dim_tiempo[mes]`, valor = `[NPS Score]`
- **Gráfico de anillos (donut)**: leyenda = `dim_canal[canal_nome]`, valor = `Total Tickets`
- **Gráfico de barras**: eje Y = `fact_interaccion[motivo]`, valor = conteo
- **Tabla**: `dim_canal[canal_nome]`, `[NPS Score]`, `[CSAT %]`, `[FCR %]` — para el panel de alertas

Aplica filtros de fecha con un **Segmentador de datos (slicer)** sobre `dim_tiempo[fecha]`.

---

## 6. Guardar como .pbix

`Archivo → Guardar como` → `cx_intelligence.pbix` → guárdalo en la carpeta `powerbi/` de este repo.

Sube ese archivo a GitHub junto con el resto del proyecto.

---

### Tip para la entrevista

Si te piden compartir el dashboard sin instalar Power BI, publícalo: `Inicio → Publicar` (requiere cuenta gratuita de Power BI Service) y comparte el link generado.
