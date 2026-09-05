import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
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


def without_html_comments(text):
    return _HTML_COMMENT.sub("", text)


def _mask_html_comments(text):
    def mask(match):
        return "".join("\r" if char == "\r" else "\n" if char == "\n" else " " for char in match.group())

    return _HTML_COMMENT.sub(mask, text)


def _front_matter_match(text):
    return _FRONT_MATTER.match(_mask_html_comments(text))


def _document_body(text):
    front = _front_matter_match(text)
    if front:
        body = text[front.end():]
    elif _FRONT_MATTER_OPEN.match(text):
        return ""
    else:
        body = text
    return without_html_comments(without_fenced_code(body))


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
    match = _front_matter_match(text)
    if not match:
        return ""
    metadata = without_html_comments(text[match.start(1):match.end(1)])
    field = re.search(rf"(?im)^{re.escape(key)}:[ \t]*(.+?)[ \t]*$", metadata)
    return field.group(1).strip() if field else ""
