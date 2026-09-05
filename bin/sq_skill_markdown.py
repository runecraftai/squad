import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
_HTML_BLOCK_OPEN = re.compile(
    r"^ {0,3}<(?P<tag>address|article|aside|blockquote|body|caption|center|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|head|header|hgroup|h1|h2|h3|h4|h5|h6|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|ol|p|pre|script|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul|style|textarea)(?:[ \t/>]|$)",
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


def _mask_inline_and_comments(line, text, offset, in_comment, inline_ticks):
    output = []
    position = 0
    while position < len(line):
        if in_comment:
            end = line.find("-->", position)
            if end < 0:
                output.append(_mask_text(line[position:]))
                return "".join(output), True, inline_ticks
            output.append(_mask_text(line[position : end + 3]))
            position = end + 3
            in_comment = False
            continue
        if inline_ticks is not None:
            close = re.search(
                rf"(?<!`)`{{{len(inline_ticks)}}}(?!`)", line[position:]
            )
            if not close:
                output.append(_mask_text(line[position:]))
                return "".join(output), in_comment, inline_ticks
            end = position + close.end()
            output.append(_mask_text(line[position:end]))
            position = end
            inline_ticks = None
            continue
        comment_start = line.find("<!--", position)
        tick_start = line.find("`", position)
        if comment_start < 0 and tick_start < 0:
            output.append(line[position:])
            break
        if comment_start >= 0 and (tick_start < 0 or comment_start < tick_start):
            output.append(line[position:comment_start])
            end = line.find("-->", comment_start + 4)
            if end < 0:
                output.append(_mask_text(line[comment_start:]))
                in_comment = True
                break
            output.append(_mask_text(line[comment_start : end + 3]))
            position = end + 3
            continue
        output.append(line[position:tick_start])
        run_end = tick_start
        while run_end < len(line) and line[run_end] == "`":
            run_end += 1
        run = line[tick_start:run_end]
        close = re.search(rf"(?<!`)`{{{len(run)}}}(?!`)", text[offset + run_end :])
        if not close:
            output.append(line[tick_start:run_end])
            position = run_end
            continue
        close_end = offset + run_end + close.end()
        if close_end <= offset + len(line):
            local_end = close_end - offset
            output.append(_mask_text(line[tick_start:local_end]))
            position = local_end
            continue
        output.append(_mask_text(line[tick_start:]))
        inline_ticks = run
        break
    return "".join(output), in_comment, inline_ticks


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
        if in_comment or inline_ticks is not None:
            masked, in_comment, inline_ticks = _mask_inline_and_comments(
                line, text, offset, in_comment, inline_ticks
            )
            lines.append(masked)
            offset += len(line)
            continue
        masked, in_comment, inline_ticks = _mask_inline_and_comments(
            line, text, offset, False, None
        )
        if in_comment or inline_ticks is not None:
            lines.append(masked)
            offset += len(line)
            continue
        opening = _HTML_BLOCK_OPEN.match(masked.rstrip("\r\n"))
        if opening:
            masked, html_tag = _mask_html_block(masked, opening.group("tag"))
            lines.append(masked)
            offset += len(line)
            continue
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
        or re.search(rf"(?im)^{re.escape(heading)}:[ \t]*[^ \t\r\n].*$", body)
    )


def front_matter(text, key):
    match = _front_matter_match(text)
    if not match:
        return ""
    metadata = text[match.start(1) : match.end(1)]
    metadata = without_html_comments(metadata)
    field = re.search(rf"(?im)^{re.escape(key)}:[ \t]*(.+?)[ \t]*$", metadata)
    return field.group(1).strip() if field else ""
