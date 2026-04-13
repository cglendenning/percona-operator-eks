#!/usr/bin/env python3
"""
Render data_platform_capabilities/index.html + capabilities.json as Markdown.

Mirrors the browser normalization (normalizeTicket / normalizePhase / normalizeRow)
and layout: eyebrow, title, intro, status legend, then the capability table with
phase cells styled like index.html (.cell.green / .yellow / .red): tinted
background, border, and inset text. Status labels and ticket lines use
white-space:nowrap and smaller type for labels so they stay on one line; the
table is wrapped in a horizontal scroll container when needed.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from html import escape, unescape
from pathlib import Path
from typing import Any
from urllib.parse import quote

VALID = frozenset({"green", "yellow", "red"})

STATUS_LABEL = {
    "green": "On track",
    "yellow": "Watch / risk",
    "red": "Blocked / gap",
}

# Matches .cell.* and --status-*-bg in data_platform_capabilities/index.html
STATUS_CELL_STYLE: dict[str, str] = {
    "green": (
        "background:rgba(74,222,128,0.2);"
        "border:1px solid rgba(74,222,128,0.55);"
        "border-radius:12px;"
        "padding:0.75rem 0.85rem;"
        "box-shadow:inset 0 1px 0 rgba(255,255,255,0.1),0 0 20px rgba(74,222,128,0.12);"
        "color:#e8eaef;"
    ),
    "yellow": (
        "background:rgba(255,245,154,0.24);"
        "border:1px solid rgba(255,245,154,0.58);"
        "border-radius:12px;"
        "padding:0.75rem 0.85rem;"
        "box-shadow:inset 0 1px 0 rgba(255,255,255,0.12),0 0 22px rgba(255,245,154,0.18);"
        "color:#e8eaef;"
    ),
    "red": (
        "background:rgba(255,133,133,0.22);"
        "border:1px solid rgba(255,133,133,0.58);"
        "border-radius:12px;"
        "padding:0.75rem 0.85rem;"
        "box-shadow:inset 0 1px 0 rgba(255,255,255,0.1),0 0 22px rgba(255,133,133,0.18);"
        "color:#e8eaef;"
    ),
}

# Compact legend chips (same palette as .cell)
LEGEND_BADGE_STYLE: dict[str, str] = {
    "green": (
        "display:inline-block;"
        "background:rgba(74,222,128,0.2);"
        "border:1px solid rgba(74,222,128,0.55);"
        "border-radius:8px;"
        "padding:0.25rem 0.55rem;"
        "font-size:0.75rem;"
        "font-weight:700;"
        "white-space:nowrap;"
        "color:#e8eaef;"
    ),
    "yellow": (
        "display:inline-block;"
        "background:rgba(255,245,154,0.24);"
        "border:1px solid rgba(255,245,154,0.58);"
        "border-radius:8px;"
        "padding:0.25rem 0.55rem;"
        "font-size:0.75rem;"
        "font-weight:700;"
        "white-space:nowrap;"
        "color:#e8eaef;"
    ),
    "red": (
        "display:inline-block;"
        "background:rgba(255,133,133,0.22);"
        "border:1px solid rgba(255,133,133,0.58);"
        "border-radius:8px;"
        "padding:0.25rem 0.55rem;"
        "font-size:0.75rem;"
        "font-weight:700;"
        "white-space:nowrap;"
        "color:#e8eaef;"
    ),
}

ACCENT_LINK = "#6ee7ff"


def legend_badge_html(status_key: str, text: str) -> str:
    sk = status_key if status_key in VALID else "yellow"
    css = LEGEND_BADGE_STYLE.get(sk, LEGEND_BADGE_STYLE["yellow"])
    return f'<span style="{css}">{escape(text)}</span>'


def _strip_tags(html: str) -> str:
    t = re.sub(r"<[^>]+>", " ", html)
    t = unescape(t)
    return re.sub(r"\s+", " ", t).strip()


def extract_page_copy(html_path: Path) -> dict[str, Any]:
    raw = html_path.read_text(encoding="utf-8")

    def grab(class_name: str) -> str | None:
        m = re.search(
            rf'<p class="{re.escape(class_name)}"[^>]*>([\s\S]*?)</p>',
            raw,
            re.IGNORECASE,
        )
        return _strip_tags(m.group(1)) if m else None

    eyebrow = grab("eyebrow") or ""
    h1_m = re.search(r"<h1[^>]*>([\s\S]*?)</h1>", raw, re.IGNORECASE)
    title = _strip_tags(h1_m.group(1)) if h1_m else "Data platform capabilities"
    sub_m = re.search(r'<p class="sub"[^>]*>([\s\S]*?)</p>', raw, re.IGNORECASE)
    sub = _strip_tags(sub_m.group(1)) if sub_m else ""

    legend_items: list[tuple[str, str]] = []
    leg_m = re.search(
        r'<div class="legend"[^>]*>([\s\S]*?)</div>',
        raw,
        re.IGNORECASE,
    )
    if leg_m:
        inner = leg_m.group(1)
        for m in re.finditer(
            r'<span><span class="dot (green|yellow|red)"[^>]*></span>\s*([^<]+)</span>',
            inner,
        ):
            legend_items.append((m.group(1), m.group(2).strip()))

    foot_m = re.search(r"<footer[^>]*>([\s\S]*?)</footer>", raw, re.IGNORECASE)
    footer = _strip_tags(foot_m.group(1)) if foot_m else ""

    return {
        "eyebrow": eyebrow,
        "title": title,
        "sub": sub,
        "legend": legend_items,
        "footer": footer,
    }


def normalize_ticket(t: Any, base_url: str) -> dict[str, str] | None:
    if isinstance(t, str):
        key = t.strip()
        sep = "" if base_url.endswith("/") else "/"
        url = (base_url + sep + quote(key, safe="")) if base_url else "#"
        return {"key": key, "url": url}
    if isinstance(t, dict) and t.get("key") is not None:
        key = str(t["key"])
        url = t.get("url")
        if not url and base_url:
            sep = "" if base_url.endswith("/") else "/"
            url = base_url + sep + quote(key, safe="")
        url = url or "#"
        return {"key": key, "url": str(url)}
    return None


def normalize_phase(phase: Any, base_url: str) -> dict[str, Any]:
    if not isinstance(phase, dict):
        phase = {}
    st = phase.get("status")
    status = st if st in VALID else "yellow"
    raw = phase.get("tickets")
    arr = raw if isinstance(raw, list) else []
    tickets = [x for x in (normalize_ticket(x, base_url) for x in arr) if x]
    return {"status": status, "tickets": tickets}


def normalize_row(row: Any, base_url: str) -> dict[str, Any]:
    name = ""
    detail = ""
    if row is not None and isinstance(row, dict):
        n = row.get("name")
        d = row.get("description")
        if n is not None and str(n).strip() != "":
            name = str(n).strip()
            detail = str(d).strip() if d is not None else ""
        elif d is not None and str(d).strip() != "":
            name = str(d).strip()
            detail = ""
        else:
            name = "—"
            detail = ""
    else:
        name = "—"
        detail = ""

    r = row if isinstance(row, dict) else {}
    return {
        "name": name,
        "detail": detail,
        "design": normalize_phase(r.get("design"), base_url),
        "develop": normalize_phase(r.get("develop"), base_url),
        "operations": normalize_phase(r.get("operations"), base_url),
    }


def escape_md_cell(text: str) -> str:
    """GFM pipe tables: escape | in cell content."""
    return text.replace("\\", "\\\\").replace("|", "\\|")


def render_capability_cell(name: str, detail: str) -> str:
    name_e = escape_md_cell(name)
    if detail:
        d = escape_md_cell(detail)
        return f"**{name_e}**<br>{d}"
    return f"**{name_e}**"


def render_phase_cell(phase: dict[str, Any]) -> str:
    status = phase["status"]
    sk = status if status in VALID else "yellow"
    label = STATUS_LABEL.get(sk, STATUS_LABEL["yellow"])
    shell = STATUS_CELL_STYLE.get(sk, STATUS_CELL_STYLE["yellow"])
    tickets: list[dict[str, str]] = phase["tickets"]

    label_html = (
        f'<div style="font-size:0.72rem;font-weight:700;line-height:1.25;'
        f'white-space:nowrap;color:#e8eaef">{escape(label)}</div>'
    )

    if not tickets:
        body = (
            f'<div style="margin-top:0.4rem;font-size:0.8125rem;font-style:italic;'
            f'opacity:0.9;white-space:nowrap">No tickets</div>'
        )
    else:
        rows: list[str] = []
        for t in tickets:
            k = escape(t["key"])
            u = escape(t["url"], quote=True)
            rows.append(
                f'<div style="white-space:nowrap">'
                f'<a href="{u}" target="_blank" rel="noopener noreferrer" '
                f'style="color:{ACCENT_LINK};font-weight:500;font-size:0.875rem;'
                f'text-decoration:none">{k}</a>'
                f"</div>"
            )
        body = (
            f'<div style="margin-top:0.45rem;display:flex;flex-direction:column;'
            f'gap:0.35rem">{"".join(rows)}</div>'
        )

    inner = label_html + body
    return (
        f'<div style="{shell}min-width:max-content;box-sizing:border-box">'
        f"{inner}</div>"
    )


def build_markdown(copy: dict[str, Any], data: dict[str, Any]) -> str:
    base_url = str(data.get("jiraBaseUrl") or "").strip()
    rows_in = data.get("capabilities")
    rows = rows_in if isinstance(rows_in, list) else []
    normalized = [normalize_row(r, base_url) for r in rows]

    eyebrow = copy.get("eyebrow") or ""
    title = copy.get("title") or "Data platform capabilities"
    sub = copy.get("sub") or ""
    legend = copy.get("legend") or []
    footer = copy.get("footer") or ""

    lines: list[str] = []
    if eyebrow:
        lines.append(f"*{eyebrow}*")
        lines.append("")
    lines.append(f"# {title}")
    lines.append("")
    if sub:
        lines.append(sub)
        lines.append("")
    if legend:
        lines.append("**Status**")
        for status_key, item in legend:
            lines.append(f"- {legend_badge_html(status_key, item)}")
        lines.append("")
    lines.append('<div style="overflow-x:auto;width:100%">')
    lines.append("")
    lines.append(
        "| Capability | Design | Develop | Operations |"
    )
    lines.append("| --- | --- | --- | --- |")
    for row in normalized:
        cap = render_capability_cell(row["name"], row["detail"])
        d = render_phase_cell(row["design"])
        v = render_phase_cell(row["develop"])
        o = render_phase_cell(row["operations"])
        lines.append(f"| {cap} | {d} | {v} | {o} |")
    lines.append("")
    lines.append("</div>")
    lines.append("")
    if footer:
        lines.append(footer)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def main() -> int:
    p = argparse.ArgumentParser(
        description="Convert data_platform_capabilities HTML + JSON to Markdown."
    )
    p.add_argument(
        "html",
        type=Path,
        help="Path to index.html (header/legend/footer copy is read from here)",
    )
    p.add_argument(
        "json",
        type=Path,
        help="Path to capabilities.json",
    )
    p.add_argument(
        "-o",
        "--output",
        type=Path,
        default=None,
        help="Write Markdown to this file (default: stdout)",
    )
    args = p.parse_args()

    if not args.html.is_file():
        print(f"not found: {args.html}", file=sys.stderr)
        return 1
    if not args.json.is_file():
        print(f"not found: {args.json}", file=sys.stderr)
        return 1

    copy = extract_page_copy(args.html)
    try:
        data = json.loads(args.json.read_text(encoding="utf-8"))
    except json.JSONDecodeError as e:
        print(f"invalid JSON: {args.json}: {e}", file=sys.stderr)
        return 1

    md = build_markdown(copy, data)
    if args.output is not None:
        args.output.write_text(md, encoding="utf-8")
    else:
        sys.stdout.write(md)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
