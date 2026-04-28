"""Phoneme / morae helpers for JA and EN — used only for alignment, not lyric display."""

from __future__ import annotations

from functools import lru_cache


def japanese_fraction(text: str) -> float:
    if not text.strip():
        return 0.0
    hits = sum(1 for ch in text if "\u3040" <= ch <= "\u30ff" or "\u3400" <= ch <= "\u9fff")
    return hits / len(text)


def is_interlude(text: str) -> bool:
    t = text.strip().lower()
    return t in {"", "(interlude)", "[interlude]", "[間奏]", "interlude", "[instrumental]"}


def line_lang(line: str) -> str:
    if japanese_fraction(line) >= 0.25:
        return "ja"
    return "en"


@lru_cache(maxsize=1)
def _g2p_en():
    from g2p_en import G2p

    return G2p()


def phoneme_tokens(line: str) -> tuple[str, list[str]]:
    stripped = line.strip()
    if not stripped:
        return ("mixed", [])

    lg = line_lang(line)
    if lg == "ja":
        seq = _ja_phone_seq(stripped)
        return ("ja", seq)

    g2 = _g2p_en()
    phonemes = [p for p in g2(stripped) if p and str(p).strip() != " "]
    clean = [_norm_phone(str(p)).strip("/") for p in phonemes]
    clean = [c for c in clean if c]
    return ("en", clean if clean else list(stripped))


def _norm_phone(s: str) -> str:
    return "".join(s.split())


def _ja_phone_seq(text: str) -> list[str]:
    """Best-effort mora-ish sequence using pyopenjtalk internals."""
    try:
        import pyopenjtalk

        lab = pyopenjtalk.run_frontend(text)
        out: list[str] = []
        # run_frontend may return list of full-context strings
        if isinstance(lab, (list, tuple)):
            for entry in lab:
                if isinstance(entry, str) and entry:
                    # Take leading phoneme field before first '-' or '+'
                    tok = entry.split("-")[0].split("+")[0]
                    if tok:
                        out.append(tok)
        elif hasattr(lab, "tolist"):
            out = [str(x) for x in lab.tolist()]
        if out:
            return out
    except Exception:
        pass
    return [ch for ch in text if not ch.isspace()]


def phonemise_lines(lines: list[str]) -> tuple[list[list[str]], list[str]]:
    phones: list[list[str]] = []
    tags: list[str] = []
    for ln in lines:
        tag, seq = phoneme_tokens(ln)
        phones.append(seq)
        tags.append(tag)
    return phones, tags
