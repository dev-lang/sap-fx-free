#!/usr/bin/env python3
"""
SAP FX Free - Generador del CSV para ZFX_FREE_SETUP
Consulta las cotizaciones del BCRA y arma el archivo de monedas (OY03) y
factores (OBBS) que procesa el programa ZFX_FREE_SETUP.

No modifica SAP: solo genera un CSV para revisar. ZFX_FREE_SETUP decide en
SAP qué falta crear (las monedas o factores que ya existen se informan como
YA EXISTE y no se tocan; si un factor existe con otros valores, se rechaza).

Requiere Python 3.10+. Es independiente: no necesita sap_fx_free.py.
Usa el mismo config.json. Solo usa la biblioteca estándar.

Uso:
  python sap_fx_setup.py                      # todas las monedas cotizadas
  python sap_fx_setup.py --solo KRW,USD       # solo esas monedas
  python sap_fx_setup.py --fecha 2026-10-23   # cotización de una fecha
  python sap_fx_setup.py --desde-config       # solo las de "currencies"
"""
from __future__ import annotations

import argparse
import csv
import logging
import sys
import urllib.error
import urllib.parse
from datetime import date, datetime
from decimal import Decimal
from pathlib import Path

import json
import urllib.request
from typing import Any

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = BASE_DIR / "config.json"
LOG = logging.getLogger("sap_fx_setup")


# --- Funciones de acceso al BCRA (copiadas de sap_fx_free.py) ---
def http_get_json(url: str, timeout: int) -> Any:
    request = urllib.request.Request(
        url,
        headers={"Accept": "application/json", "User-Agent": "SAP-FX-Free/0.1"}
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        if response.status != 200:
            raise RuntimeError(f"HTTP inesperado: {response.status} para {url}")
        charset = response.headers.get_content_charset() or "utf-8"
        return json.loads(response.read().decode(charset))

def unwrap_bcra(payload):
    if not isinstance(payload, dict):
        raise ValueError("La respuesta de la API no es un objeto JSON.")

    # El BCRA devuelve status=200 cuando la consulta es exitosa.
    status = payload.get("status")

    if status not in (None, 0, "0", 200, "200"):
        raise ValueError(
            f"El BCRA devolvió status={status}: "
            f"{payload.get('error') or payload}"
        )

    if "results" not in payload:
        raise ValueError(
            "La respuesta no contiene la propiedad 'results'."
        )

    return payload["results"]

def get_detail_rows(results: Any) -> tuple[str | None, list[dict]]:
    # La API puede devolver un objeto con fecha/detalle o una lista de resultados históricos.
    if isinstance(results, dict):
        result_date = results.get("fecha")
        details = results.get("detalle", [])
        if not isinstance(details, list):
            raise ValueError("La propiedad 'detalle' no es una lista.")
        return result_date, details
    if isinstance(results, list):
        all_rows: list[dict] = []
        dates: list[str] = []
        for item in results:
            if not isinstance(item, dict):
                continue
            if item.get("fecha"):
                dates.append(str(item["fecha"]))
            details = item.get("detalle", [])
            if isinstance(details, list):
                all_rows.extend(details)
        return (max(dates) if dates else None), all_rows
    raise ValueError("Formato de 'results' no reconocido.")

def load_config(path: Path) -> dict:
    if not path.exists():
        raise ValueError(
            f"No existe {path}. Copiar config.example.json como config.json "
            "y ajustarlo (o indicar otro archivo con --config)."
        )
    with path.open("r", encoding="utf-8") as f:
        config = json.load(f)
    if not isinstance(config.get("currencies"), list) or not config["currencies"]:
        raise ValueError("config.json debe incluir una lista no vacía en 'currencies'.")
    return config

# ---------------------------------------------------------------------------
# Datos ISO 4217: código -> (numérico, texto largo, texto corto)
# TCURC-ALTWR = numérico (3), TCURT-LTEXT máx. 40, TCURT-KTEXT máx. 15.
# El texto solo se usa si la moneda NO existe en SAP (si existe, se ignora).
# ---------------------------------------------------------------------------
ISO = {
    "AUD": ("036", "Dólar australiano", "Dólar austral."),
    "AWG": ("533", "Florín arubeño", "Florín arubeño"),
    "BOB": ("068", "Boliviano", "Boliviano"),
    "BRL": ("986", "Real brasileño", "Real"),
    "CAD": ("124", "Dólar canadiense", "Dólar canad."),
    "CHF": ("756", "Franco suizo", "Franco suizo"),
    "CLP": ("152", "Peso chileno", "Peso chileno"),
    "CNH": ("",    "Yuan renminbi offshore (CNH)", "Yuan offshore"),
    "CNY": ("156", "Yuan renminbi", "Yuan"),
    "COP": ("170", "Peso colombiano", "Peso colomb."),
    "CZK": ("203", "Corona checa", "Corona checa"),
    "DKK": ("208", "Corona danesa", "Corona danesa"),
    "EUR": ("978", "Euro", "Euro"),
    "GBP": ("826", "Libra esterlina", "Libra esterl."),
    "HKD": ("344", "Dólar de Hong Kong", "Dólar HK"),
    "ILS": ("376", "Nuevo séquel israelí", "Séquel"),
    "INR": ("356", "Rupia india", "Rupia india"),
    "JPY": ("392", "Yen japonés", "Yen"),
    "KRW": ("410", "Won surcoreano", "Won"),
    "MXN": ("484", "Peso mexicano", "Peso mexicano"),
    "NIO": ("558", "Córdoba oro nicaragüense", "Córdoba"),
    "NOK": ("578", "Corona noruega", "Corona norueg."),
    "NZD": ("554", "Dólar neozelandés", "Dólar NZ"),
    "PEN": ("604", "Sol peruano", "Sol"),
    "PYG": ("600", "Guaraní paraguayo", "Guaraní"),
    "RSD": ("941", "Dinar serbio", "Dinar serbio"),
    "RUB": ("643", "Rublo ruso", "Rublo"),
    "SEK": ("752", "Corona sueca", "Corona sueca"),
    "SGD": ("702", "Dólar de Singapur", "Dólar Singapur"),
    "TRY": ("949", "Lira turca", "Lira turca"),
    "USD": ("840", "Dólar estadounidense", "Dólar EE.UU."),
    "UYU": ("858", "Peso uruguayo", "Peso uruguayo"),
    "VES": ("928", "Bolívar soberano venezolano", "Bolívar sob."),
    "VND": ("704", "Dong vietnamita", "Dong"),
    "XAG": ("961", "Plata (onza troy)", "Plata"),
    "XAU": ("959", "Oro (onza troy)", "Oro"),
    "XDR": ("960", "Derecho especial de giro (FMI)", "DEG"),
    "ZAR": ("710", "Rand sudafricano", "Rand"),
}

# Valores por defecto de la sección "setup" de config.json
DEFAULT_SETUP = {
    # EUR: en este sistema M EUR->ARS se deriva vía EURX (no se toca).
    # REF: Com. A 3500, no es una moneda. XAU/XAG: metales, no divisas.
    "exclude": ["EUR", "REF", "XAU", "XAG"],
    "valid_from": "1800-01-01",
    # Factores ya definidos en el sistema; tienen prioridad sobre la regla.
    # Valor = factor de la moneda (ARS 1) o [factor moneda, factor ARS].
    "factors": {
        "CLP": 1000, "COP": 1000, "JPY": 100, "MXN": 100,
        "PYG": 1000, "VES": 1000, "VND": 1000,
    },
}

COLUMNS = [
    "currency", "iso_code", "alt_key", "long_text", "short_text",
    "rate_type", "to_currency", "valid_from", "from_factor", "to_factor",
]


MAX_SAP_RATE = Decimal("9999.99999")
WARN_SAP_RATE = Decimal("8000")


def parse_factor(code, value) -> tuple[int, int]:
    """setup.factors acepta 1000 (factor de la moneda, ARS = 1) o
    [1, 10] (factor de la moneda, factor ARS). Ambos potencias de 10."""
    if isinstance(value, (list, tuple)):
        if len(value) != 2:
            raise ValueError(f"setup.factors.{code}: usar un número o [de, a].")
        ff, tf = int(value[0]), int(value[1])
    else:
        ff, tf = int(value), 1
    for f in (ff, tf):
        if f < 1 or str(f).strip("0") != "1":
            raise ValueError(f"setup.factors.{code}: {value} no es potencia de 10.")
    if ff != 1 and tf != 1:
        raise ValueError(f"setup.factors.{code}: uno de los dos factores tiene que ser 1.")
    return ff, tf


def factor_por_regla(rate: Decimal) -> int:
    """Cotización >= 1 ARS: factor 1. Menor a 1 ARS: 1000 (o más, hasta que
    la cotización por ese factor llegue a 1), para no perder decimales."""
    factor = 1
    if rate < 1:
        factor = 1000
        while rate * factor < 1 and factor < 10**9:
            factor *= 10
    return factor


def clip(text: str, size: int, campo: str, code: str) -> str:
    if len(text) > size:
        LOG.warning("%s de %s supera %d caracteres; se recorta.", campo, code, size)
        return text[:size]
    return text


def build_url(config: dict, fecha: str | None) -> str:
    url = config["source"]["url"]
    if fecha:
        datetime.strptime(fecha, "%Y-%m-%d")
        url += ("&" if "?" in url else "?") + urllib.parse.urlencode({"fecha": fecha})
    return url


def fetch(config: dict, fecha: str | None) -> tuple[str, list[dict]]:
    """Devuelve (fecha, [{api_code, code, description, rate}]) con rate > 0."""
    url = build_url(config, fecha)
    timeout = int(config["source"].get("timeout_seconds", 20))
    results = unwrap_bcra(http_get_json(url, timeout))
    source_date, details = get_detail_rows(results)
    if not source_date:
        raise ValueError("No se encontró la fecha de cotización en la respuesta.")
    code_map = {str(k).upper(): str(v).upper()
                for k, v in (config.get("code_map") or {}).items()}
    units_cfg = {str(k).upper(): v for k, v in (config.get("api_units") or {}).items()}
    rows: dict[str, dict] = {}
    for item in details:
        if not isinstance(item, dict):
            continue
        api_code = str(item.get("codigoMoneda", "")).strip().upper()
        if not api_code:
            continue
        code = code_map.get(api_code, api_code)
        try:
            rate = Decimal(str(item.get("tipoCotizacion")))
        except Exception:
            continue
        if not rate.is_finite() or rate <= 0:
            continue                    # sin cotización (p. ej. ARS, metales)
        units = Decimal(str(units_cfg.get(api_code, 1)))
        rate = rate / units
        if code in rows:
            LOG.warning("%s aparece más de una vez en la respuesta; se usa la primera.", code)
            continue
        rows[code] = {"api_code": api_code, "code": code, "rate": rate,
                      "description": str(item.get("descripcion", "")).strip()}
    return source_date, [rows[k] for k in sorted(rows)]


def build_setup(config: dict, quotes: list[dict], solo: set[str] | None) -> list[dict]:
    setup = {**DEFAULT_SETUP, **(config.get("setup") or {})}
    exclude = {c.upper() for c in setup.get("exclude", [])}
    factors = {str(k).upper(): parse_factor(k, v)
               for k, v in (setup.get("factors") or {}).items()}
    valid_from = str(setup.get("valid_from", "1800-01-01"))
    datetime.strptime(valid_from, "%Y-%m-%d")
    sap = config.get("sap", {})
    rate_type = str(sap.get("exchange_rate_type", "M"))
    target = str(sap.get("target_currency", "ARS")).upper()

    out = []
    for q in quotes:
        code = q["code"]
        if solo is not None and code not in solo:
            continue
        if code == target:
            continue
        if code in exclude and (solo is None or code not in solo):
            LOG.info("%s excluida (setup.exclude).", code)
            continue
        if len(code) > 5:
            LOG.warning("%s: código de más de 5 caracteres, no válido en SAP; se omite.", code)
            continue
        if code in ISO:
            num, ltext, ktext = ISO[code]
        else:
            # Moneda nueva para el script: texto del BCRA, revisar antes de usar.
            LOG.warning("%s no está en la tabla ISO del script; usar texto del BCRA y revisar.", code)
            num, ltext, ktext = "", q["description"].title(), q["description"].title()
        if code in factors:
            ffact, tfact = factors[code]
        else:
            ffact, tfact = factor_por_regla(q["rate"]), 1
            # Tope de SAP: EXCH_RATE admite hasta 9999,99999 ARS por
            # FROM_FACTOR unidades. Si no entra, se usa factor ARS 10.
            while q["rate"] * ffact / tfact > MAX_SAP_RATE and tfact < 10**6:
                tfact *= 10
        sap_rate = q["rate"] * ffact / tfact
        if sap_rate >= WARN_SAP_RATE:
            LOG.warning("%s: cotización en SAP %.5f cerca del máximo (9999,99999). "
                        "Prever un factor ARS 10 con nueva fecha (setup.factors: [%d, %d]).",
                        code, sap_rate, ffact, tfact * 10)
        out.append({
            "currency": code,
            "iso_code": code if num or code in ISO else "",
            "alt_key": num,
            "long_text": clip(ltext, 40, "long_text", code),
            "short_text": clip(ktext, 15, "short_text", code),
            "rate_type": rate_type,
            "to_currency": target,
            "valid_from": valid_from,
            "from_factor": ffact,
            "to_factor": tfact,
            "_rate": q["rate"],
        })
    if solo:
        faltan = sorted(solo - {r["currency"] for r in out})
        for code in faltan:
            LOG.warning("%s no tiene cotización en la respuesta del BCRA; no se incluye.", code)
    return out


def write_csv(path: Path, rows: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    # UTF-8 con BOM: es lo que lee ZFX_FREE_SETUP (y Excel lo abre bien).
    with path.open("w", newline="", encoding="utf-8-sig") as f:
        w = csv.DictWriter(f, fieldnames=COLUMNS, extrasaction="ignore")
        w.writeheader()
        w.writerows(rows)


def main() -> int:
    p = argparse.ArgumentParser(description="Genera el CSV de monedas/factores para ZFX_FREE_SETUP.")
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="Ruta a config.json")
    p.add_argument("--fecha", help="Fecha de cotización AAAA-MM-DD (por defecto, la última)")
    p.add_argument("--solo", help="Lista de monedas SAP separadas por coma (p. ej. KRW,USD)")
    p.add_argument("--desde-config", action="store_true",
                   help="Usar solo las monedas de 'currencies' de config.json")
    p.add_argument("--salida", type=Path, help="Archivo CSV de salida")
    args = p.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        config = load_config(args.config)
        solo = None
        if args.solo:
            solo = {c.strip().upper() for c in args.solo.split(",") if c.strip()}
        elif args.desde_config:
            solo = {str(c).strip().upper() for c in config["currencies"]}

        source_date, quotes = fetch(config, args.fecha)
        rows = build_setup(config, quotes, solo)
        if not rows:
            raise ValueError("No quedó ninguna moneda para el archivo; no se generó.")

        out = args.salida or (BASE_DIR / config.get("output_dir", "output")
                              / f"zfx_free_setup_{date.today().isoformat()}.csv")
        write_csv(out, rows)

        print(f"Cotización del BCRA usada para los factores: {source_date}")
        print(f"Monedas en el archivo: {len(rows)}")
        for r in rows:
            print(f"  {r['currency']:<5} {r['long_text']:<32} "
                  f"factor {r['from_factor']}:{r['to_factor']}  (cot. {r['_rate']:f})")
        print(f"CSV: {out}")
        print()
        print("Para config.json -> \"currencies\":")
        print("  " + ", ".join(f'"{r["currency"]}"' for r in rows))
        print()
        print("Siguiente paso: ZFX_FREE_SETUP en SIMULACIÓN con este archivo.")
        print("Recordatorio: ZFX_FREE_LOAD solo carga monedas de su lista blanca (mt_exp).")
        return 0
    except (OSError, ValueError, RuntimeError, urllib.error.URLError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
