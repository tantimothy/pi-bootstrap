#!/usr/bin/env python3
"""Renders a group's mnemon insight graph as an interactive HTML network.

Always invoked by export-mnemon-graph.sh against a throwaway SQLite
snapshot (see that script's own header) — never the live mnemon.db — so
this file assumes a plain, unlocked, non-WAL-contended sqlite3.connect()
is safe.

Schema queried here (confirmed against mnemon's own upstream source,
github.com/mnemon-dev/mnemon's internal/store/db.go — NOT the `memories`/
`edges(type, description)` shape an earlier, uncorrected chat guessed at):
  insights(id, content, category, importance, tags, entities, source,
            access_count, created_at, updated_at, deleted_at,
            last_accessed_at, embedding, effective_importance)
  edges(source_id, target_id, edge_type, weight, metadata, created_at)
"""

import sqlite3
import sys

try:
    from pyvis.network import Network
except ImportError:
    print("Error: pyvis isn't installed. export-mnemon-graph.sh should have", file=sys.stderr)
    print("caught this already — run: python3 -m pip install --user pyvis", file=sys.stderr)
    sys.exit(1)

EDGE_COLORS = {
    "causal": "#f1c40f",
    "temporal": "#2ecc71",
    "entity": "#9b59b6",
    "semantic": "#3498db",
}


def node_color(importance):
    if importance >= 8:
        return "#e74c3c"
    if importance >= 5:
        return "#3498db"
    return "#7f8c8d"


def wrap(text, width=50):
    text = text or ""
    return (text[:width] + "…") if len(text) > width else text


def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <snapshot-db-path> <output-html-path>", file=sys.stderr)
        sys.exit(1)

    db_path, output_html = sys.argv[1], sys.argv[2]
    conn = sqlite3.connect(db_path)
    cursor = conn.cursor()

    net = Network(height="900px", width="100%", bgcolor="#1a1a1a", font_color="white", directed=True)
    net.force_atlas_2based()

    cursor.execute(
        "SELECT id, content, importance, effective_importance, category "
        "FROM insights WHERE deleted_at IS NULL"
    )
    rows = cursor.fetchall()
    if not rows:
        print("No (non-deleted) insights found in this store — nothing to render.", file=sys.stderr)
        sys.exit(1)

    for node_id, content, importance, effective_importance, category in rows:
        importance = importance if importance is not None else 5
        title = f"[{category}] {content}\nimportance={importance} effective={effective_importance:.2f}" \
            if effective_importance is not None else f"[{category}] {content}\nimportance={importance}"
        net.add_node(
            node_id,
            label=f"[{importance}] {wrap(content)}",
            title=title,
            value=importance,
            color=node_color(importance),
        )

    node_ids = {r[0] for r in rows}
    cursor.execute("SELECT source_id, target_id, edge_type, weight, metadata FROM edges")
    edge_count = 0
    for source, target, edge_type, weight, metadata in cursor.fetchall():
        # Edges can reference deleted insights (deleted_at is a soft delete,
        # the edges table has no corresponding cleanup) — skip rather than
        # let pyvis silently create phantom nodes for them.
        if source not in node_ids or target not in node_ids:
            continue
        color = EDGE_COLORS.get(edge_type, "#95a5a6")
        title = f"{edge_type} (weight={weight})"
        if metadata and metadata != "{}":
            title += f"\n{metadata}"
        net.add_edge(source, target, title=title, color=color, value=weight or 1.0)
        edge_count += 1

    conn.close()

    net.save_graph(output_html)
    print(f"Rendered {len(rows)} insights and {edge_count} edges -> {output_html}")


if __name__ == "__main__":
    main()
