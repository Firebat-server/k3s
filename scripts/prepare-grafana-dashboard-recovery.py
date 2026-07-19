#!/usr/bin/env python3
"""Normalize exported Grafana dashboards for the K3s monitoring stack."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
from typing import Any


LEGACY_DATASOURCE_UIDS = {
    "P8E80F9AEF21F6940": "loki",
    "af0345y7h7tvka": "loki",
    "bf034415j9pfka": "prometheus",
}

EXPECTED_DASHBOARDS = {
    "fgc-nginx01-web-analytics.json",
    "nginx-traffic-map.json",
    "rYdddlPWk.json",
}


def migrate_worldmap(panel: dict[str, Any]) -> None:
    panel_id = panel.get("id", 30)
    grid_pos = panel.get("gridPos", {"h": 9, "w": 24, "x": 0, "y": 3})
    panel.clear()
    panel.update(
        {
            "id": panel_id,
            "title": "Visitor Geo Map",
            "type": "geomap",
            "pluginVersion": "13.1.0",
            "gridPos": grid_pos,
            "datasource": {"type": "loki", "uid": "loki"},
            "targets": [
                {
                    "datasource": {"type": "loki", "uid": "loki"},
                    "expr": (
                        "topk(100, sum by (geoip_country_name, geoip_city_name, "
                        "geoip_location_latitude, geoip_location_longitude) "
                        "(count_over_time({job=\"nginx_access\", host=\"$host\", "
                        "geoip_location_latitude!=\"\"}[$__range])))"
                    ),
                    "queryType": "instant",
                    "refId": "A",
                }
            ],
            "fieldConfig": {"defaults": {}, "overrides": []},
            "options": {
                "basemap": {"config": {}, "name": "Layer 0", "type": "default"},
                "controls": {
                    "mouseWheelZoom": True,
                    "showAttribution": True,
                    "showDebug": False,
                    "showMeasure": False,
                    "showScale": False,
                    "showZoom": True,
                },
                "layers": [
                    {
                        "config": {
                            "showLegend": True,
                            "style": {
                                "color": {"fixed": "dark-green"},
                                "opacity": 0.75,
                                "size": {
                                    "field": "Value",
                                    "fixed": 8,
                                    "max": 30,
                                    "min": 5,
                                },
                            },
                        },
                        "location": {
                            "latitude": "geoip_location_latitude",
                            "longitude": "geoip_location_longitude",
                            "mode": "coords",
                        },
                        "name": "Requests",
                        "tooltip": True,
                        "type": "markers",
                    }
                ],
                "view": {"id": "fit", "lat": 0, "lon": 0, "zoom": 1},
            },
        }
    )


def normalize(value: Any) -> None:
    if isinstance(value, list):
        for item in value:
            normalize(item)
        return

    if not isinstance(value, dict):
        return

    if value.get("type") == "grafana-worldmap-panel":
        migrate_worldmap(value)
        return

    if value.get("type") == "graph":
        value["type"] = "timeseries"
        value["pluginVersion"] = "13.1.0"

    if value.get("type") == "volkovlabs-echarts-panel":
        value["pluginVersion"] = "7.2.5"

    datasource = value.get("datasource")
    if isinstance(datasource, str) and datasource in LEGACY_DATASOURCE_UIDS:
        value["datasource"] = LEGACY_DATASOURCE_UIDS[datasource]
    elif isinstance(datasource, dict):
        uid = datasource.get("uid")
        if uid in LEGACY_DATASOURCE_UIDS:
            datasource["uid"] = LEGACY_DATASOURCE_UIDS[uid]

    expression = value.get("expr")
    if isinstance(expression, str):
        value["expr"] = expression.replace(
            '{filename="$filename", host="$host"}',
            '{job="nginx_access", filename="$filename", host="$host"}',
        )

    for item in value.values():
        normalize(item)


def normalize_variables(dashboard: dict[str, Any]) -> None:
    variables = dashboard.get("templating", {}).get("list", [])
    for variable in variables:
        name = variable.get("name")
        if name not in {"host", "filename", "job"}:
            continue
        variable["datasource"] = "loki"
        if name == "host":
            query = 'label_values({job="nginx_access"}, host)'
        elif name == "filename":
            query = 'label_values({job="nginx_access"}, filename)'
        else:
            query = 'label_values({job="nginx_access"}, job)'
        variable["definition"] = query
        variable["query"] = query


def prepare(source: Path, destination: Path) -> None:
    dashboard = json.loads(source.read_text(encoding="utf-8"))
    normalize(dashboard)
    if dashboard.get("uid") == "fgc-nginx01-web-analytics":
        normalize_variables(dashboard)

    dashboard["id"] = None
    dashboard["version"] = 1
    tags = dashboard.setdefault("tags", [])
    if "restored-from-docker" not in tags:
        tags.append("restored-from-docker")

    rendered = json.dumps(dashboard, ensure_ascii=False, indent=2) + "\n"
    for legacy_uid in LEGACY_DATASOURCE_UIDS:
        if legacy_uid in rendered:
            raise ValueError(f"legacy datasource UID remains in {source.name}: {legacy_uid}")
    if "grafana-worldmap-panel" in rendered or '"type": "graph"' in rendered:
        raise ValueError(f"unsupported legacy panel remains in {source.name}")

    destination.write_text(rendered, encoding="utf-8")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path, help="Directory containing exported JSON files")
    parser.add_argument("destination", type=Path, help="Chart dashboards directory")
    args = parser.parse_args()

    available = {path.name for path in args.source.glob("*.json")}
    missing = EXPECTED_DASHBOARDS - available
    if missing:
        raise SystemExit(f"missing exported dashboards: {', '.join(sorted(missing))}")

    args.destination.mkdir(parents=True, exist_ok=True)
    for filename in sorted(EXPECTED_DASHBOARDS):
        prepare(args.source / filename, args.destination / filename)


if __name__ == "__main__":
    main()
