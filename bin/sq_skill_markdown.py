import re


_FENCE_OPEN = re.compile(r"^ {0,3}(`{3,}|~{3,})")


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


def section(text, heading):
    text = without_fenced_code(text)
    match = re.search(
        rf"(?im)^##\s+{re.escape(heading)}\s*$\n(.*?)(?=^##\s+|\Z)",
        text,
        re.DOTALL,
    )
    if match:
        return match.group(1).strip()
    label = re.search(rf"(?im)^{re.escape(heading)}:\s*(.+?)\s*$", text)
    return label.group(1).strip() if label else ""


def has_section(text, heading):
    text = without_fenced_code(text)
    return bool(
        re.search(rf"(?im)^##\s+{re.escape(heading)}\s*$", text)
        or re.search(rf"(?im)^{re.escape(heading)}:\s*.+$", text)
    )


def front_matter(text, key):
    text = without_fenced_code(text)
    match = re.match(
        r"\A---[ \t]*\r?\n(.*?)(?:\r?\n)(?:---|\.\.\.)[ \t]*(?:\r?\n|\Z)",
        text,
        re.DOTALL,
    )
    if not match:
        return ""
    field = re.search(rf"(?im)^{re.escape(key)}:\s*(.+?)\s*$", match.group(1))
    return field.group(1).strip() if field else ""
