# SAP FX Free

Carga de cotizaciones del **BCRA** (Banco Central de la República Argentina) en **SAP ECC**. Se compone de:

- **Scripts Python** que bajan los datos de la API pública del BCRA y generan CSV para revisar.
- **Programas ABAP** (Z) que cargan esos CSV en SAP con interfaces estándar: BAPIs de tipos de cambio y batch input sobre SM30.

Probado en SAP ECC 6.0 EHP6 (SAP_BASIS 731, Unicode). El código ABAP evita la sintaxis 7.40+: no usa declaraciones inline, `NEW`, string templates ni expresiones constructoras.

## Contenido

```
sap-fx-free/
├── python/
│   ├── sap_fx_free.py         Cotizaciones del BCRA  -> CSV para ZFX_FREE_LOAD
│   ├── sap_fx_setup.py        Monedas y factores     -> CSV para ZFX_FREE_SETUP
│   └── config.example.json    Copiar como config.json
├── abap/
│   ├── ZFX_FREE_LOAD.abap     Carga cotizaciones tipo M -> ARS (TCURR) vía BAPI
│   ├── ZFX_FREE_FETCH.abap    Descarga directa desde SAP (HTTPS) -> ZFX_FREE_LOAD
│   ├── ZFX_FREE_SETUP.abap    Alta de monedas (OY03) y factores (OBBS) por batch input
│   └── ZFX_FREE_HTTP_TEST.abap  Prueba de conexión HTTPS a la API del BCRA
└── csv_ejemplos/
    ├── ZFX_FREE_LOAD/
    └── ZFX_FREE_SETUP/
```

## Principios de diseño

- **Nunca se escribe directo en las tablas de SAP.**
  - Las cotizaciones se graban con `BAPI_EXCHRATE_CREATEMULTIPLE`.
  - Monedas y factores se dan de alta por SM30, con las mismas validaciones que el alta manual, y quedan registrados en una orden de customizing.
- **La simulación es el modo por defecto.** La ejecución real exige elegirla explícitamente y confirmar.
- **Todo o nada.** Se valida el archivo completo antes de grabar. Si una línea se rechaza, no se carga ninguna.
- **No sobrescribe.** Si una cotización o un factor ya existe, se informa y no se modifica.
- **Verificación posterior.** Después de grabar, se relee cada alta para confirmarla.

## Instalación

### Python

Requiere Python 3.10 o superior. Solo usa la biblioteca estándar.

```
cd python
copy config.example.json config.json     (Linux/macOS: cp)
python sap_fx_free.py --check-config
```

### ABAP

1. SE38 → crear `ZFX_FREE_LOAD` y `ZFX_FREE_SETUP` (programa ejecutable, paquete a elección).
2. Utilidades → Otras utilidades → Carga/descarga → **Cargar** → elegir el `.abap`.
   - Los archivos están en **UTF-8**. Si en el diálogo aparece el campo *Encoding*, elegir UTF-8.
   - Si después de cargar se ven caracteres raros en los acentos, convertir el archivo a ANSI (Windows-1252) y volver a cargarlo.
3. Verificar sintaxis (**Ctrl+F2**) y activar (**Ctrl+F3**).

## Uso

### 1. Monedas y factores

Solo hace falta cuando aparece una moneda nueva o hay que cambiar un factor.

```
cd python
python sap_fx_setup.py                   # todas las monedas que cotiza el BCRA
python sap_fx_setup.py --solo USD,BRL    # solo algunas
python sap_fx_setup.py --fecha 2026-10-23
python sap_fx_setup.py --desde-config    # solo las de "currencies"
```

En SAP: **ZFX_FREE_SETUP** con el CSV generado.

1. Primero en **simulación**.
2. Después en **ejecución real**, con una orden de customizing abierta y modo de batch input **N**.

Lo que ya existe se informa como *YA EXISTE*. Si un factor existe con otros valores, la línea se rechaza.

### 2. Cotizaciones (diario)

```
cd python
python sap_fx_free.py
```

En SAP: **ZFX_FREE_LOAD** con `output/bcra_quotes_AAAA-MM-DD.csv`.

1. Primero en **simulación**.
2. Después en **carga real**. Si hay advertencias revisadas, tildar *Acepto las advertencias*.

#### Alternativa: descarga directa desde SAP (sin Python)

**ZFX_FREE_FETCH** hace lo mismo que `sap_fx_free.py`, pero desde SAP. Consulta la API por HTTPS, arma el mismo CSV en memoria y llama a ZFX_FREE_LOAD, que valida y carga como siempre.

- Opciones: fecha (vacía = la última publicada), simulación o carga real, y *Solo mostrar el CSV generado*.
- Incluye solo las monedas con factores M X → ARS en OBBS. Las demás aparecen en el log como *Descarga: … excluida*.

Requisitos en SAP:

1. ICM con HTTPS activo. Lo confirma `ZFX_FREE_HTTP_TEST`.
2. En **STRUST → SSL client Anonymous**, importar la raíz **ISRG Root X1** de Let's Encrypt (`https://letsencrypt.org/certs/isrgrootx1.der`), agregarla a la lista de certificados y grabar.
3. Salida a Internet desde el servidor de aplicación.

Se carga toda moneda que tenga factores **M X → ARS** en OBBS vigentes a la fecha. Si en OBBS el par deriva de otro tipo de cotización (columna *Alt. ERT*), la línea se informa como *OMITIDO*.

## Configuración (`config.json`)

| Clave | Uso |
|---|---|
| `source.url` | Endpoint de cotizaciones del BCRA |
| `currencies` | Monedas (códigos SAP) que baja `sap_fx_free.py` |
| `code_map` | Código BCRA → código SAP (p. ej. `MXP → MXN`, `VEB → VES`) |
| `api_units` | Unidades en que el BCRA publica una moneda (p. ej. VND cada 1.000) |
| `sap` | Tipo de cotización (`M`) y moneda destino (`ARS`) |
| `setup.exclude` | Monedas que `sap_fx_setup.py` no incluye |
| `setup.factors` | Factores ya definidos: `1000` o `[1, 10]` (moneda : ARS) |
| `setup.valid_from` | Fecha de los factores nuevos (por defecto 1800-01-01) |

## Monedas

El BCRA publica 43 códigos. Con la configuración de ejemplo se cargan **34**:

- AUD, AWG, BOB, BRL, CAD, CHF, CLP, CNH, CNY, COP
- CZK, DKK, GBP, HKD, ILS, INR, JPY, MXN, NIO, NOK
- NZD, PEN, PYG, RSD, RUB, SEK, SGD, TRY, USD, UYU
- VES, VND, XDR, ZAR

Quedan afuera:

| Código | Motivo |
|---|---|
| ARS | Moneda destino |
| EUR | Excluido en la configuración de ejemplo (ver *Notas*) |
| REF | Dólar de referencia Com. A 3500: no es una moneda |
| XAU, XAG | Oro y plata, sin cotización |
| ATS, DEM, ESP, ITL | Monedas reemplazadas por el euro, sin cotización |

La API devuelve un solo valor por moneda (`tipoCotizacion`, pesos por unidad). No distingue comprador y vendedor.

## Notas

- **Tope de SAP.** La cotización (`UKURS`) admite hasta **9.999,99999** ARS por unidad de factor.
  - Desde **8.000**, los dos lados advierten.
  - Para seguir cargando, dar de alta un factor nuevo con fecha nueva y factor ARS 10, por ejemplo `"GBP": [1, 10]`.
- **Monedas con pocos pesos por unidad.** Si una moneda vale menos de 1 ARS, `sap_fx_setup.py` le asigna factor 1000 para no perder decimales.
- **EUR.** En algunos sistemas, la entrada M EUR → ARS de OBBS deriva del tipo `EURX`. En ese caso una cotización M para EUR no se usaría, y ZFX_FREE_LOAD la omite. Revisar OB07/OBBS antes de habilitarlo.
- **Fuente.** Las cotizaciones son las publicadas por el BCRA en su API de estadísticas cambiarias. Verificar que el valor sea el adecuado para el uso contable de cada empresa.

## Ejemplos

| Archivo | Uso |
|---|---|
| `ZFX_FREE_LOAD/bcra_quotes_2026-10-23_todas.csv` | Cotizaciones del 23/10/2026 (35 monedas) |
| `ZFX_FREE_LOAD/bcra_quotes_2026-10-23_solo_USD.csv` | Una sola cotización, para una primera prueba |
| `ZFX_FREE_SETUP/zfx_free_setup_2026-10-24.csv` | Factores M → ARS desde 1800 + CNH/VES/XDR |
| `ZFX_FREE_SETUP/zfx_free_setup_MXN_2026-10-26.csv` | Cambio de factor de MXN a 1:1 con fecha nueva |
| `ZFX_FREE_SETUP/zfx_free_setup_PRUEBA_ZZT.csv` | Prueba real con una moneda ficticia (borrarla después) |
| `ZFX_FREE_SETUP/zfx_free_setup_PRUEBA_negativos.csv` | Casos que deben rechazarse (solo simulación) |

## Mi instalación

Sistema de laboratorio con ECC 6.0 EHP6 sobre Sybase ASE 15.7, mandante 001. Los programas Z están en `$TMP`.

- **Monedas creadas:** CNH, VES (ISO 928) y XDR (ISO 960).
- **Factores:** 26 entradas M X → ARS desde el 01.01.1800, más MXN 1:1 desde el 26.10.2026 (antes 100:1).
- **EUR:** M EUR → ARS deriva de `EURX`; pendiente de definir.
- **HTTPS:** CommonCryptoLib 8.5.56 (kernel 722), TLS 1.2. Se agregó ISRG Root X1 al PSE SSL cliente anónimo.
- **Órdenes:** el customizing quedó en una orden propia. Las pruebas (moneda ficticia ZZT, KRW) están en otra orden que no se transporta.

## Licencia

[MIT](LICENSE)
