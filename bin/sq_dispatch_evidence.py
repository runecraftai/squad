"""The recommendation-evidence allowlist shared by the Jev client and the writer."""
import math
import re

SECRET_SHAPE = re.compile(
    r"(?<![A-Za-z0-9])(sk|pk|ghp|gho|ghs|ghu|ghr|xox[abprs]|glpat)[-_][A-Za-z0-9_-]{8,}"
    r"|github_pat_[A-Za-z0-9_]{8,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{8,}[.]|bearer[ ]"
    r"|(token|secret|passwd|password|api[_-]?key|credential)[=:]"
    r"|(?<![A-Za-z0-9_+/])(?!(?:[0-9a-f]{40}|[0-9a-f]{64})(?![A-Za-z0-9_+/]))[A-Za-z0-9_+/]{32,}",
    re.IGNORECASE)


def recordable_text(value):
    return isinstance(value, str) and re.fullmatch(r"[!-~]{1,128}", value) is not None \
        and SECRET_SHAPE.search(value) is None


def unit_interval(value):
    return type(value) in (int, float) and math.isfinite(value) and 0 <= value <= 1


def recordable_probability(name, score):
    return recordable_text(name) and unit_interval(score)


def recordable_probabilities(value):
    if not isinstance(value, dict):
        return {}
    return {name: score for name, score in value.items() if recordable_probability(name, score)}


def recordable_answer(answer):
    """The bounded per-question fields a recommendation answer may record, or None."""
    if not isinstance(answer, dict):
        return None
    entry = {}
    kind = answer.get("type")
    if isinstance(kind, str) and re.fullmatch(r"[a-z]{1,32}", kind):
        entry["type"] = kind
    if "choice" in answer and recordable_text(answer["choice"]):
        entry["choice"] = answer["choice"]
    if "answer" in answer and (isinstance(answer["answer"], bool) or answer["answer"] is None):
        entry["answer"] = answer["answer"]
    if "confidence" in answer and unit_interval(answer["confidence"]):
        entry["confidence"] = answer["confidence"]
    if "probabilities" in answer:
        kept = recordable_probabilities(answer["probabilities"])
        if kept:
            entry["probabilities"] = kept
    return entry
