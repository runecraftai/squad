import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")
_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
_HTML_BLOCK_OPEN = re.compile(
    r"^ {0,3}<(?P<tag>[A-Za-z][A-Za-z0-9-]*)(?=[ \t/>])(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>",
    re.IGNORECASE,
)
_HTML_TAG = re.compile(
    r"<(?P<closing>/)?(?P<tag>[A-Za-z][A-Za-z0-9-]*)(?=[ \t/>])(?:[^\"'<>]|\"[^\"]*\"|'[^']*')*>",
    re.IGNORECASE,
)
_HTML_OPEN_START = re.compile(
    r"^ {0,3}<(?P<tag>[A-Za-z][A-Za-z0-9-]*)(?=[ \t/>]|$)",
    re.IGNORECASE,
)
_HTML_ATTRIBUTE_START = re.compile(
    r"^[ \t]*(?:/?>|[A-Za-z_:][A-Za-z0-9_.:-]*(?=[ \t=>/]|$))"
)
_HTML_VOID_TAGS = frozenset(
    {"area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr"}
)
_HTML_RAW_TAGS = frozenset({"script", "style", "textarea", "title"})
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


def _is_self_closing(match):
    return bool(re.search(r"/[ \t]*>$", match.group(0)))


def _is_html_opener_continuation(line, opener):
    if opener["quote"]:
        return True
    return bool(_HTML_ATTRIBUTE_START.match(line.rstrip("\r\n")))


def _consume_html_opener(line, opener, position=0):
    quote = opener["quote"]
    last_nonspace = opener["last_nonspace"]
    while position < len(line):
        char = line[position]
        if quote:
            if char == quote:
                quote = None
        elif char in "\"'":
            quote = char
        elif char == ">":
            stack = (
                []
                if opener["tag"] in _HTML_VOID_TAGS or last_nonspace == "/"
                else [opener["tag"]]
            )
            stack, in_comment, end = _scan_html_line(
                line, stack, False, position + 1
            )
            return _mask_text(line[:end]) + line[end:], None, stack, in_comment
        if not char.isspace():
            last_nonspace = char
        position += 1
    opener["quote"] = quote
    opener["last_nonspace"] = last_nonspace
    return _mask_text(line), opener, [], False


def _scan_html_line(line, stack, in_comment, position=0):
    while position < len(line):
        if stack and stack[-1] in _HTML_RAW_TAGS:
            raw_tag = stack[-1]
            close = re.search(rf"</{re.escape(raw_tag)}[ \t]*>", line[position:], re.IGNORECASE)
            if not close:
                return stack, in_comment, len(line)
            position += close.end()
            stack.pop()
            if not stack:
                return stack, False, position
            continue
        if in_comment:
            end = line.find("-->", position)
            if end < 0:
                return stack, True, len(line)
            position = end + 3
            in_comment = False
            continue
        comment_start = line.find("<!--", position)
        tag_match = _HTML_TAG.search(line, position)
        if comment_start >= 0 and (tag_match is None or comment_start < tag_match.start()):
            position = comment_start + 4
            in_comment = True
            continue
        if tag_match is None:
            return stack, in_comment, len(line)
        tag = tag_match.group("tag").lower()
        if tag_match.group("closing"):
            if stack and stack[-1] == tag:
                stack.pop()
                if not stack:
                    return stack, False, tag_match.end()
        elif tag not in _HTML_VOID_TAGS and not _is_self_closing(tag_match):
            stack.append(tag)
        position = tag_match.end()
    return stack, in_comment, position


def _mask_html_line(line, stack, in_comment, position=0):
    stack, in_comment, end = _scan_html_line(line, stack, in_comment, position)
    return _mask_text(line[:end]) + line[end:], stack, in_comment


def without_fenced_code_and_html_comments(text):
    lines = []
    fence_char = None
    fence_length = 0
    html_stack = []
    html_comment = False
    html_opener = None
    html_pending = []
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
        if html_opener:
            if not _is_html_opener_continuation(line, html_opener):
                lines.extend(raw for raw, masked in html_pending)
                html_pending = []
                html_opener = None
            else:
                masked, html_opener, html_stack, html_comment = _consume_html_opener(
                    line, html_opener
                )
                html_pending.append((line, masked))
                if html_opener is None:
                    lines.extend(masked for raw, masked in html_pending)
                    html_pending = []
                offset += len(line)
                continue
        if html_stack:
            masked, html_stack, html_comment = _mask_html_line(
                line, html_stack, html_comment
            )
            lines.append(masked)
            offset += len(line)
            continue
        if not in_comment and inline_ticks is None:
            opening = _HTML_BLOCK_OPEN.match(content)
            if opening:
                tag = opening.group("tag").lower()
                html_stack = (
                    []
                    if tag in _HTML_VOID_TAGS or _is_self_closing(opening)
                    else [tag]
                )
                html_comment = False
                masked, html_stack, html_comment = _mask_html_line(
                    line, html_stack, html_comment, opening.end()
                )
                lines.append(masked)
                offset += len(line)
                continue
            opener = _HTML_OPEN_START.match(content)
            if opener:
                html_opener = {
                    "tag": opener.group("tag").lower(),
                    "quote": None,
                    "last_nonspace": opener.group("tag")[-1],
                }
                masked, html_opener, html_stack, html_comment = _consume_html_opener(
                    line, html_opener, opener.end()
                )
                if html_opener:
                    html_pending.append((line, masked))
                else:
                    lines.append(masked)
                offset += len(line)
                continue
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
        lines.append(masked)
        offset += len(line)
    if html_pending:
        lines.extend(raw for raw, masked in html_pending)
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
