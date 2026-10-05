#!/usr/bin/env python3
"""redact.py — scrub credential-looking material from text BEFORE it leaves the box.

stdin -> stdout. Used only for EXTERNAL API calls (the Legion is yours; no redaction there).
Fails closed: on any internal error it exits non-zero and prints nothing, so callers skip
the external call instead of sending raw text.

Redacts: PEM blocks, JWTs, well-known key prefixes, URL credentials, `password:`-style
assignments, long digit runs (cards/IDs/IBAN-ish), and any high-entropy token.
Output is capped (default 4000 chars) — transcript only, never a file.
"""
import math
import re
import sys

LIMIT = int(sys.argv[1]) if len(sys.argv) > 1 else 4000
MASK = "[REDACTED]"

PATTERNS = [
    re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\Z)", re.S),
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]*"),
    re.compile(r"\b(?:sk|pk|rk)[-_](?:live|test|proj|ant|or|cc)?[-_]?[A-Za-z0-9_-]{16,}"),
    re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr|github_pat)_[A-Za-z0-9_]{20,}"),
    re.compile(r"\b(?:AKIA|ASIA|AIza)[A-Za-z0-9_-]{12,}"),
    re.compile(r"\bxox[abprs]-[A-Za-z0-9-]{10,}"),
    re.compile(r"\b[A-Za-z][A-Za-z0-9+.-]*://[^\s/:@]+:[^\s/@]+@"),
    re.compile(r"(?i)\b(pass(?:word|wd|phrase)?|pwd|secret|token|api[_-]?key|auth|credential)s?\b\s*[:=]\s*\S+"),
    re.compile(r"\b(?:\d[ -]?){9,}\b"),
    re.compile(r"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){3,7}(?: ?[A-Z0-9]{1,4})?\b"),
]


def entropy(s: str) -> float:
    counts = {}
    for ch in s:
        counts[ch] = counts.get(ch, 0) + 1
    return -sum(c / len(s) * math.log2(c / len(s)) for c in counts.values())


def high_entropy(m: "re.Match[str]") -> str:
    tok = m.group(0)
    classes = sum(bool(re.search(p, tok)) for p in (r"[a-z]", r"[A-Z]", r"\d"))
    if len(tok) >= 20 and classes >= 2 and entropy(tok) >= 3.6:
        return MASK
    if len(tok) >= 32 and entropy(tok) >= 3.0:
        return MASK
    return tok


def main() -> int:
    text = sys.stdin.read()
    for pat in PATTERNS:
        text = pat.sub(MASK, text)
    text = re.sub(r"[A-Za-z0-9+/=_-]{20,}", high_entropy, text)
    sys.stdout.write(text[:LIMIT])
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as exc:  # fail closed
        sys.stderr.write(f"redact: {exc}\n")
        sys.exit(3)
