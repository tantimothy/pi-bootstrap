#!/usr/bin/env python3
"""Renders a group's mnemon insight graph as a navigable set of static HTML
pages — an index plus one page per insight, with its edges as real links —
instead of export-mnemon-graph.py's force-directed network, which turns
unreadable once a store has a few thousand edges (confirmed live: 353
insights / 4262 edges rendered as an indecipherable tangle).

Always invoked by export-mnemon-pages.sh against a throwaway SQLite
snapshot (see that script's own header) — never the live mnemon.db.

Schema queried here (confirmed against mnemon's own upstream source,
github.com/mnemon-dev/mnemon's internal/store/db.go):
  insights(id, content, category, importance, tags, entities, source,
            access_count, created_at, updated_at, deleted_at,
            last_accessed_at, embedding, effective_importance)
  edges(source_id, target_id, edge_type, weight, metadata, created_at)

Pure stdlib (sqlite3, html, json, pathlib) — unlike export-mnemon-graph.py,
this needs no pyvis/venv.
"""

import html
import json
import re
import sqlite3
import sys
from pathlib import Path

EDGE_TYPE_ORDER = ["causal", "temporal", "entity", "semantic"]
EDGE_TYPE_LABEL = {
    "causal": "Causal (led to / caused by)",
    "temporal": "Temporal (happened around)",
    "entity": "Entity (shares a subject with)",
    "semantic": "Semantic (related in meaning to)",
}

STYLE = """
:root { color-scheme: light dark; }
body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
       max-width: 900px; margin: 0 auto; padding: 1.5rem;
       line-height: 1.5; }
a { color: #3498db; text-decoration: none; }
a:hover { text-decoration: underline; }
table { border-collapse: collapse; width: 100%; }
th, td { text-align: left; padding: 0.4rem 0.6rem; border-bottom: 1px solid rgba(128,128,128,0.3); }
th { cursor: pointer; user-select: none; }
th:hover { color: #3498db; }
.badge { display: inline-block; padding: 0.1rem 0.5rem; border-radius: 1rem;
         font-size: 0.8rem; background: rgba(52,152,219,0.15); }
.importance-hi { color: #e74c3c; font-weight: bold; }
.importance-mid { color: #3498db; }
.importance-lo { color: #7f8c8d; }
.meta { color: #7f8c8d; font-size: 0.9rem; }
.content-box { background: rgba(128,128,128,0.08); border-radius: 0.5rem;
               padding: 1rem; margin: 1rem 0; font-size: 1.05rem; }
.edge-group { margin: 1rem 0; }
.edge-group h3 { margin-bottom: 0.3rem; font-size: 1rem; }
.edge-list { list-style: none; padding-left: 0; margin: 0; }
.edge-list li { padding: 0.3rem 0; border-bottom: 1px solid rgba(128,128,128,0.15); }
.edge-weight { color: #7f8c8d; font-size: 0.85rem; }
.controls { margin: 1rem 0; display: flex; gap: 0.75rem; flex-wrap: wrap; }
.controls input, .controls select { padding: 0.4rem; font-size: 0.95rem; }
.back { display: inline-block; margin-bottom: 1rem; }
.chip { display: inline-block; background: rgba(128,128,128,0.15); border-radius: 1rem;
        padding: 0.1rem 0.6rem; font-size: 0.8rem; margin: 0.1rem; }
"""


def esc(s):
    return html.escape(s or "", quote=True)


def slugify(insight_id):
    # mnemon ids are opaque hash-format tokens (per upstream's own comment
    # in db.go) — sanitized defensively rather than trusted verbatim as a
    # filename, since nothing in this environment or mnemon's own docs
    # actually guarantees a specific character set.
    s = re.sub(r"[^A-Za-z0-9._-]", "_", insight_id or "")
    return s or "unknown"


def importance_class(importance):
    if importance >= 8:
        return "importance-hi"
    if importance >= 5:
        return "importance-mid"
    return "importance-lo"


def parse_json_list(raw):
    try:
        val = json.loads(raw) if raw else []
        return val if isinstance(val, list) else []
    except (json.JSONDecodeError, TypeError):
        return []


def page_shell(title, body):
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{esc(title)}</title>
<style>{STYLE}</style></head>
<body>{body}</body></html>
"""


def build_index(insights, out_dir, edge_counts):
    rows = []
    for ins in sorted(insights, key=lambda i: (i["effective_importance"] or 0, i["importance"]), reverse=True):
        n_edges = edge_counts.get(ins["id"], 0)
        rows.append(f"""<tr data-category="{esc(ins['category'])}" data-content="{esc(ins['content'].lower())}">
  <td class="{importance_class(ins['importance'])}">{ins['importance']}</td>
  <td><span class="badge">{esc(ins['category'])}</span></td>
  <td><a href="insights/{slugify(ins['id'])}.html">{esc(ins['content'][:100])}</a></td>
  <td class="meta">{n_edges}</td>
</tr>""")

    categories = sorted({ins["category"] for ins in insights})
    cat_options = "".join(f'<option value="{esc(c)}">{esc(c)}</option>' for c in categories)

    body = f"""
<h1>Mnemon Insights ({len(insights)})</h1>
<p class="meta">Click a row to open that insight and follow its edges to related ones.</p>
<div class="controls">
  <input type="search" id="q" placeholder="Filter by text…" oninput="filterRows()">
  <select id="cat" onchange="filterRows()">
    <option value="">All categories</option>
    {cat_options}
  </select>
</div>
<table id="tbl">
<thead><tr><th onclick="sortBy(0)">Importance</th><th onclick="sortBy(1)">Category</th><th>Content</th><th onclick="sortBy(3)">Edges</th></tr></thead>
<tbody>
{"".join(rows)}
</tbody>
</table>
<script>
function filterRows() {{
  const q = document.getElementById('q').value.toLowerCase();
  const cat = document.getElementById('cat').value;
  for (const tr of document.querySelectorAll('#tbl tbody tr')) {{
    const matchesQ = !q || tr.dataset.content.includes(q);
    const matchesCat = !cat || tr.dataset.category === cat;
    tr.style.display = (matchesQ && matchesCat) ? '' : 'none';
  }}
}}
function sortBy(col) {{
  const tbody = document.querySelector('#tbl tbody');
  const rows = Array.from(tbody.querySelectorAll('tr'));
  const numeric = col === 0 || col === 3;
  const dir = tbody.dataset.sortCol == col && tbody.dataset.sortDir == 'asc' ? 'desc' : 'asc';
  rows.sort((a, b) => {{
    let av = a.children[col].textContent.trim(), bv = b.children[col].textContent.trim();
    if (numeric) {{ av = parseFloat(av) || 0; bv = parseFloat(bv) || 0; }}
    const cmp = av < bv ? -1 : av > bv ? 1 : 0;
    return dir === 'asc' ? cmp : -cmp;
  }});
  rows.forEach(r => tbody.appendChild(r));
  tbody.dataset.sortCol = col;
  tbody.dataset.sortDir = dir;
}}
</script>
"""
    (out_dir / "index.html").write_text(page_shell("Mnemon Insights", body))


def build_insight_page(ins, outgoing, incoming, out_dir, id_to_content):
    tags = parse_json_list(ins["tags"])
    entities = parse_json_list(ins["entities"])
    chips = "".join(f'<span class="chip">{esc(t)}</span>' for t in tags + entities)

    def edge_section(title_prefix, edges, other_key):
        if not edges:
            return ""
        by_type = {}
        for e in edges:
            by_type.setdefault(e["edge_type"], []).append(e)
        groups = []
        for et in EDGE_TYPE_ORDER:
            if et not in by_type:
                continue
            items = "".join(
                f'<li><a href="{slugify(e[other_key])}.html">'
                f'{esc(id_to_content.get(e[other_key], "(unknown insight)")[:90])}</a> '
                f'<span class="edge-weight">weight={e["weight"]}</span></li>'
                for e in by_type[et]
            )
            groups.append(f"""<div class="edge-group">
  <h3>{esc(EDGE_TYPE_LABEL.get(et, et))} — {len(by_type[et])}</h3>
  <ul class="edge-list">{items}</ul>
</div>""")
        return f"<h2>{title_prefix} ({len(edges)})</h2>" + "".join(groups)

    body = f"""
<a class="back" href="../index.html">← All insights</a>
<div class="content-box">{esc(ins['content'])}</div>
<p class="meta">
  <span class="badge">{esc(ins['category'])}</span>
  importance={ins['importance']} (effective={ins['effective_importance']:.2f}) &middot;
  source={esc(ins['source'])} &middot; created {esc(ins['created_at'])}
</p>
{f'<p>{chips}</p>' if chips else ''}
{edge_section("Outgoing edges", outgoing, "target_id")}
{edge_section("Incoming edges", incoming, "source_id")}
"""
    (out_dir / "insights" / f"{slugify(ins['id'])}.html").write_text(
        page_shell(ins["content"][:60], body)
    )


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <snapshot-db-path> <output-dir>", file=sys.stderr)
        sys.exit(1)

    db_path, output_dir = sys.argv[1], Path(sys.argv[2])
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    cursor = conn.cursor()

    cursor.execute(
        "SELECT id, content, category, importance, tags, entities, source, "
        "created_at, effective_importance FROM insights WHERE deleted_at IS NULL"
    )
    insights = [dict(r) for r in cursor.fetchall()]
    if not insights:
        print("No (non-deleted) insights found in this store — nothing to render.", file=sys.stderr)
        sys.exit(1)

    id_to_content = {i["id"]: i["content"] for i in insights}
    node_ids = set(id_to_content)

    cursor.execute("SELECT source_id, target_id, edge_type, weight, metadata FROM edges")
    outgoing_by_id, incoming_by_id, edge_counts = {}, {}, {}
    skipped = 0
    for row in cursor.fetchall():
        e = dict(row)
        # Edges can reference deleted insights (deleted_at is a soft
        # delete; edges has no corresponding cleanup) — skip rather than
        # link to a page that was never generated.
        if e["source_id"] not in node_ids or e["target_id"] not in node_ids:
            skipped += 1
            continue
        outgoing_by_id.setdefault(e["source_id"], []).append(e)
        incoming_by_id.setdefault(e["target_id"], []).append(e)
        edge_counts[e["source_id"]] = edge_counts.get(e["source_id"], 0) + 1
        edge_counts[e["target_id"]] = edge_counts.get(e["target_id"], 0) + 1
    conn.close()

    (output_dir / "insights").mkdir(parents=True, exist_ok=True)
    build_index(insights, output_dir, edge_counts)
    for ins in insights:
        build_insight_page(
            ins, outgoing_by_id.get(ins["id"], []), incoming_by_id.get(ins["id"], []),
            output_dir, id_to_content,
        )

    print(f"Rendered {len(insights)} insight pages ({skipped} dangling edges to deleted insights skipped) -> {output_dir / 'index.html'}")


if __name__ == "__main__":
    main()
