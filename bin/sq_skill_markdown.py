import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
_FRONT_MATTER_OPEN = re.compile(r"\A---[ \t]*(?:\r?\n|\Z)")
_FRONT_MATTER = re.compile(
    r"\A---[ \t]*\r?\n(.*?)(?:\r?\n)(?:---|\.\.\.)[ \t]*(?:\r?\n|\Z)",
    re.DOTALL,
)


def _mask_text(text):
    return "".join("\r" if char == "\r" else "\n" if char == "\n" else " " for char in text)


def without_html_comments(text):
    return _HTML_COMMENT.sub(lambda match: _mask_text(match.group()), text)


def _mask_html_comments(text):
    return without_html_comments(text)


def _mask_comments_in_line(line, in_comment):
    output = []
    position = 0
    if in_comment:
        end = line.find("-->")
        if end < 0:
            return _mask_text(line), True
        output.append(_mask_text(line[: end + 3]))
        position = end + 3
        in_comment = False
    while position < len(line):
        start = line.find("<!--", position)
        if start < 0:
            output.append(line[position:])
            break
        output.append(line[position:start])
        end = line.find("-->", start + 4)
        if end < 0:
            output.append(_mask_text(line[start:]))
            in_comment = True
            break
        output.append(_mask_text(line[start : end + 3]))
        position = end + 3
    return "".join(output), in_comment


def without_fenced_code_and_html_comments(text):
    lines = []
    fence_char = None
    fence_length = 0
    in_comment = False
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        if fence_char:
            closing = re.fullmatch(
                rf" {{0,3}}{re.escape(fence_char)}{{{fence_length},}}[ \t]*",
                content,
            )
            if closing:
                fence_char = None
            continue
        if not in_comment:
            opening = _FENCE_OPEN.match(content)
            if opening:
                fence_char = opening.group(1)[0]
                fence_length = len(opening.group(1))
                continue
        masked, in_comment = _mask_comments_in_line(line, in_comment)
        lines.append(masked)
    return "".join(lines)


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
    return without_fenced_code_and_html_comments(body)


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
    metadata = text[match.start(1) : match.end(1)]
    metadata = without_html_comments(metadata)
    field = re.search(rf"(?im)^{re.escape(key)}:[ \t]*(.+?)[ \t]*$", metadata)
    return field.group(1).strip() if field else ""
