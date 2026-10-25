"""Runs in the reader's own Python environment, never inside Hermes.

Reads one JSON request on stdin and writes one JSON reply on stdout:
  {"kind": "ping"}                                   -> which libraries are present
  {"kind": "html", "html": str, "url": str, "markdown": bool} -> Trafilatura text
  {"kind": "pdf", "path": str}                       -> pypdf text
"""
import json
import sys

MAX_PDF_PAGES = 300
MAX_TEXT = 2_000_000


def _have(name):
    try:
        __import__(name)
        return True
    except Exception:
        return False


def _html(request):
    import trafilatura
    text = trafilatura.extract(
        request["html"], url=request.get("url") or None,
        output_format="markdown" if request.get("markdown", True) else "txt",
        include_comments=False, include_tables=True, include_images=False, include_links=False,
        deduplicate=True,
    )
    title = ""
    try:
        meta = trafilatura.extract_metadata(request["html"], default_url=request.get("url") or None)
        title = (meta.title or "") if meta is not None else ""
    except Exception:
        pass
    return {"ok": bool(text), "title": title, "text": (text or "")[:MAX_TEXT]}


def _pdf(request):
    from pypdf import PdfReader
    reader = PdfReader(request["path"])
    if reader.is_encrypted:
        try:
            reader.decrypt("")
        except Exception:
            return {"ok": False, "error": "locked"}
    parts, size = [], 0
    for index, page in enumerate(reader.pages):
        if index >= MAX_PDF_PAGES or size > MAX_TEXT:
            break
        try:
            text = page.extract_text() or ""
        except Exception:
            text = ""
        parts.append(text.strip())
        size += len(text)
    title = ""
    try:
        title = str((reader.metadata or {}).get("/Title") or "")
    except Exception:
        pass
    return {"ok": True, "title": title, "text": "\n\n".join(p for p in parts if p)[:MAX_TEXT],
            "pages": len(reader.pages)}


def main():
    try:
        request = json.loads(sys.stdin.buffer.read().decode("utf-8"))
        kind = request.get("kind")
        if kind == "ping":
            reply = {"ok": True, "html": _have("trafilatura"), "pdf": _have("pypdf")}
        elif kind == "html":
            reply = _html(request)
        elif kind == "pdf":
            reply = _pdf(request)
        else:
            reply = {"ok": False, "error": "unknown request"}
    except Exception as error:
        reply = {"ok": False, "error": type(error).__name__}
    sys.stdout.write(json.dumps(reply, ensure_ascii=False))


if __name__ == "__main__":
    main()
