"""Minimal reader for `xctrace export` table XML (resolves the id/ref compression)."""
import xml.etree.ElementTree as ET


def read_table(path):
    """Return (column mnemonics, rows) where each row is a dict mnemonic -> text value.

    Process cells are returned as their formatted label, e.g. "UXM Perf (16634)".
    Sentinel cells become None.
    """
    root = ET.parse(path).getroot()
    schema = next(root.iter("schema"))
    cols = [c.findtext("mnemonic") for c in schema.findall("col")]
    seen = {}

    def value(el):
        if el.tag == "sentinel":
            return None
        ref = el.get("ref")
        if ref is not None:
            el = seen[ref]
        if el.tag == "process":
            return el.get("fmt")
        if el.tag in ("narrative",):
            return el.get("fmt")
        return el.text if el.text is not None else el.get("fmt")

    rows = []
    for row in root.iter("row"):
        # register ids first (children may be referenced by later cells)
        for el in row.iter():
            i = el.get("id")
            if i is not None:
                seen[i] = el
        cells = list(row)
        rows.append({m: value(c) for m, c in zip(cols, cells)})
    return cols, rows
