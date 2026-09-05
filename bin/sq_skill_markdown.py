import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_FRONT_MATTER_OPEN = re.compile(r"\A---[ \t]*(?:\r?\n|\Z)")
_FRONT_MATTER = re.compile(
    r"\A---[ \t]*\r?\n(.*?)(?:\r?\n)(?:---|\.\.\.)[ \t]*(?:\r?\n|\Z)",
    re.DOTALL,
)


def without_fenced_code(text):
    lines = []
    fence_char = None
    fence_length = 0
    for line in text.splitlines():
        if fence_char:
            closing = re.match(
                rf"^ {{0,3}}{re.escape(fence_char)}{{{fence_length},}}[ \t]*$",
                line,
            )
            if closing:
                fence_char = None
            continue
        opening = _FENCE_OPEN.match(line)
        if opening:
            fence_char = opening.group(1)[0]
            fence_length = len(opening.group(1))
            continue
        lines.append(line)
    return "\n".join(lines)


def _document_body(text):
    front = _FRONT_MATTER.match(text)
    if front:
        return without_fenced_code(text[front.end():])
    if _FRONT_MATTER_OPEN.match(text):
        return ""
    return without_fenced_code(text)


def section(text, heading):
    body = _document_body(text)
    match = re.search(
        rf"(?im)^##[ \t]+{re.escape(heading)}[ \t]*\r?\n(.*?)(?=^##[ \t]+|\Z)",
        body,
        re.DOTALL,
    )
    if match:
        return match.group(1).strip()
    label = re.search(rf"(?im)^{re.escape(heading)}:[ \t]*(.+?)[ \t]*$", body)
    return label.group(1).strip() if label else ""


def has_section(text, heading):
    body = _document_body(text)
    return bool(
        re.search(rf"(?im)^##[ \t]+{re.escape(heading)}[ \t]*\r?$", body)
        or re.search(rf"(?im)^{re.escape(heading)}:[ \t]*.+$", body)
    )


def front_matter(text, key):
    match = _FRONT_MATTER.match(text)
    if not match:
        return ""
    field = re.search(rf"(?im)^{re.escape(key)}:[ \t]*(.+?)[ \t]*$", match.group(1))
    return field.group(1).strip() if field else ""
