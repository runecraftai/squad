import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
_HTML_BLOCK_OPEN = re.compile(
    r"^ {0,3}<(?P<tag>address|article|aside|blockquote|body|caption|center|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|head|header|hgroup|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|ol|p|pre|script|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul|style|textarea)(?:[ \t/>]|$)",
    re.IGNORECASE,
)
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


def _mask_inline_code(line, text, offset, ticks):
    output = []
    position = 0
    while position < len(line):
        start = line.find("`", position)
        if start < 0:
            output.append(_mask_text(line[position:]) if ticks is not None else line[position:])
            return "".join(output), ticks
        run_end = start
        while run_end < len(line) and line[run_end] == "`":
            run_end += 1
        run = line[start:run_end]
        if ticks is not None:
            if run != ticks:
                output.append(_mask_text(line[position:run_end]))
                position = run_end
                continue
            output.append(_mask_text(line[position:run_end]))
            ticks = None
            position = run_end
            continue
        close = re.search(rf"(?<!`)`{{{len(run)}}}(?!`)", text[offset + run_end :])
        if close:
            close_end = offset + run_end + close.end()
            output.append(line[position:start])
            output.append(_mask_text(line[start:]))
            if close_end <= offset + len(line):
                local_end = close_end - offset
                output[-1] = _mask_text(line[start:local_end])
                output.append(line[local_end:])
                position = local_end
                continue
            return "".join(output), run
        output.append(line[position:run_end])
        position = run_end
    return "".join(output), ticks


def _mask_html_block(line, tag):
    content = line.rstrip("\r\n")
    close = re.search(rf"</{re.escape(tag)}[ \t]*>", content, re.IGNORECASE)
    if close:
        return _mask_text(line[: close.end()]) + line[close.end() :], None
    return _mask_text(line), tag


def without_fenced_code_and_html_comments(text):
    lines = []
    fence_char = None
    fence_length = 0
    html_tag = None
    in_comment = False
    inline_ticks = None
    offset = 0
    for line in text.splitlines(keepends=True):
        content = line.rstrip("\r\n")
        if fence_char:
            closing = re.fullmatch(
                rf" {{0,3}}{re.escape(fence_char)}{{{fence_length},}}[ \t]*",
                content,
            )
            if closing:
                fence_char = None
            offset += len(line)
            continue
        if html_tag:
            masked, html_tag = _mask_html_block(line, html_tag)
            lines.append(masked)
            offset += len(line)
            continue
        if not in_comment and inline_ticks is None:
            opening = _FENCE_OPEN.match(content)
            if opening:
                fence_char = opening.group(1)[0]
                fence_length = len(opening.group(1))
                offset += len(line)
                continue
        masked, in_comment = _mask_comments_in_line(line, in_comment)
        if in_comment:
            lines.append(masked)
            offset += len(line)
            continue
        if inline_ticks is None:
            opening = _HTML_BLOCK_OPEN.match(masked.rstrip("\r\n"))
            if opening:
                masked, html_tag = _mask_html_block(masked, opening.group("tag"))
                lines.append(masked)
                offset += len(line)
                continue
        masked, inline_ticks = _mask_inline_code(masked, text, offset, inline_ticks)
        lines.append(masked)
        offset += len(line)
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
        rf"(?im)^##[ \t]+{re.escape(heading)}[ \t]*\r?\n(.*?)(?=^##(?:[ \t]+.*)?[ \t]*\r?$|\Z)",
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
