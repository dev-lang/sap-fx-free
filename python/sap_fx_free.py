#!/usr/bin/env python3
"""
SAP FX Free - Etapa 1
Descarga cotizaciones del BCRA y genera CSV/JSON para revisión.
No modifica SAP ni escribe directamente en TCURR.
Requiere Python 3.10+; usa únicamente la biblioteca estándar.
"""
from __future__ import annotations

import argparse
import csv
import json
import logging
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import date, datetime
from decimal import ROUND_HALF_UP, Decimal, InvalidOperation
from pathlib import Path
from typing import Any

BASE_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = BASE_DIR / "config.json"
LOG = logging.getLogger("sap_fx_free")
# ZFX_FREE_LOAD acepta como máximo 9 decimales en la columna rate.
RATE_QUANTUM = Decimal("0.000000001")


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


def decimal_value(value: Any, field: str) -> Decimal:
    try:
        result = Decimal(str(value))
    except (InvalidOperation, TypeError, ValueError):
        raise ValueError(f"Valor numérico inválido en {field}: {value!r}")
    if not result.is_finite() or result <= 0:
        raise ValueError(f"El valor de {field} debe ser positivo y finito: {value!r}")
    return result


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


def fetch_quotes(config: dict) -> tuple[str, list[dict]]:
    source = config["source"]
    url = source["url"]
    timeout = int(source.get("timeout_seconds", 20))
    payload = http_get_json(url, timeout)
    results = unwrap_bcra(payload)
    source_date, details = get_detail_rows(results)
    if not source_date:
        raise ValueError("No se encontró la fecha de cotización en la respuesta.")
    # Rechazar fechas que no tengan el formato ISO esperado.
    datetime.strptime(source_date, "%Y-%m-%d")

    # "currencies" se expresa en códigos SAP (ISO). "code_map" traduce el
    # código del BCRA al de SAP cuando difieren (p. ej. MXP -> MXN).
    wanted = {str(code).strip().upper() for code in config["currencies"]}
    code_map = {
        str(k).strip().upper(): str(v).strip().upper()
        for k, v in (config.get("code_map") or {}).items()
    }
    found: dict[str, dict] = {}
    for item in details:
        if not isinstance(item, dict):
            continue
        api_code = str(item.get("codigoMoneda", "")).strip().upper()
        code = code_map.get(api_code, api_code)
        if code not in wanted:
            continue
        if code in found:
            raise ValueError(f"La moneda {code} aparece más de una vez en la respuesta (revisar code_map).")
        raw_rate = item.get("tipoCotizacion")
        if raw_rate in (None, "", "N/A"):
            LOG.warning("Sin tipoCotizacion para %s; se omite.", code)
            continue
        try:
            rate = decimal_value(raw_rate, f"tipoCotizacion de {code}")
        except ValueError as exc:
            # Una moneda sin valor válido (p. ej. 0) no frena al resto:
            # se omite y queda avisado. ZFX_FREE_LOAD no la ve.
            LOG.warning("%s; se omite %s.", exc, code)
            continue
        # "api_units": unidades a las que se refiere la cotización del BCRA
        # (p. ej. VND se publica cada 1.000). Se normaliza a 1 unidad.
        units = Decimal(str((config.get("api_units") or {}).get(api_code, 1)))
        if units <= 0:
            raise ValueError(f"api_units inválido para {api_code}: {units}")
        if units != 1:
            rate = rate / units
        # Máximo 9 decimales (p. ej. VND/1000 con 8 decimales daría 11 y
        # ZFX_FREE_LOAD rechazaría el archivo completo).
        rounded = rate.quantize(RATE_QUANTUM, rounding=ROUND_HALF_UP)
        if rounded <= 0:
            LOG.warning("Cotización de %s demasiado chica (%s); se omite.", code, rate)
            continue
        if rounded != rate:
            LOG.info("Cotización de %s redondeada a 9 decimales: %s -> %s", code, rate, rounded)
        rate = rounded.normalize()
        found[code] = {
            "currency": code,
            "description": str(item.get("descripcion", "")).strip(),
            "rate_type": str(config.get("sap", {}).get("exchange_rate_type", "M")),
            "from_currency": code,
            "to_currency": str(config.get("sap", {}).get("target_currency", "ARS")).upper(),
            "valid_from": source_date,
            # Interpretación de trabajo: pesos por una unidad de moneda extranjera.
            # Confirmar esta convención contra el manual/API y el customizing SAP antes de cargar.
            "rate": format(rate, "f"),
            "source": source.get("name", "BCRA"),
            "source_url": url,
            "source_date": source_date,
            "source_field": "tipoCotizacion" if api_code == code else f"tipoCotizacion ({api_code})",
            "status": "REVIEW_REQUIRED"
        }

    missing = sorted(wanted - set(found))
    for code in missing:
        LOG.warning("La moneda configurada %s no apareció en la respuesta.", code)

    if not found:
        raise ValueError(
            "No se obtuvo ninguna cotización configurada. "
            "No se generó un archivo vacío; revisar respuesta y config."
        )
    return source_date, [found[k] for k in sorted(found)]


def write_outputs(config: dict, source_date: str, rows: list[dict]) -> tuple[Path, Path]:
    out_dir = BASE_DIR / config.get("output_dir", "output")
    out_dir.mkdir(parents=True, exist_ok=True)
    csv_path = out_dir / f"bcra_quotes_{source_date}.csv"
    json_path = out_dir / f"bcra_quotes_{source_date}.json"

    columns = [
        "currency", "description", "rate_type", "from_currency", "to_currency",
        "valid_from", "rate", "source", "source_url", "source_date",
        "source_field", "status"
    ]
    with csv_path.open("w", newline="", encoding="utf-8-sig") as f:
        writer = csv.DictWriter(f, fieldnames=columns, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    with json_path.open("w", encoding="utf-8") as f:
        json.dump(
            {"schema_version": "1.0", "generated_at": datetime.now().astimezone().isoformat(),
             "source_date": source_date, "records": rows},
            f, ensure_ascii=False, indent=2
        )
    return csv_path, json_path


def main() -> int:
    parser = argparse.ArgumentParser(description="Descarga cotizaciones del BCRA para revisión previa a SAP.")
    parser.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="Ruta a config.json")
    parser.add_argument("--check-config", action="store_true", help="Valida configuración sin consultar Internet")
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
    try:
        config = load_config(args.config)
        if args.check_config:
            print(f"Configuración válida: {args.config}")
            print("Monedas:", ", ".join(config["currencies"]))
            return 0
        source_date, rows = fetch_quotes(config)
        csv_path, json_path = write_outputs(config, source_date, rows)
        print(f"Fecha informada por la fuente: {source_date}")
        print(f"Cotizaciones recibidas: {len(rows)}")
        for row in rows:
            print(f"  {row['currency']}/{row['to_currency']} = {row['rate']} [{row['status']}]")
        print(f"CSV:  {csv_path}")
        print(f"JSON: {json_path}")
        print("ATENCIÓN: los registros están marcados REVIEW_REQUIRED y no se cargaron en SAP.")
        return 0
    except (OSError, ValueError, RuntimeError, urllib.error.URLError, json.JSONDecodeError) as exc:
        LOG.error("%s", exc)
        return 1


if __name__ == "__main__":
    sys.exit(main())
