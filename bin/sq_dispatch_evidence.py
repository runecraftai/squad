"""The recommendation-evidence allowlist shared by the Jev client and the writer."""
import re

QUESTION_KEY = "lane"
DESIGN_KEY = "needs_design_decision"
ANSWER_QUESTIONS = frozenset({QUESTION_KEY, DESIGN_KEY})
UNAVAILABLE_REASONS = frozenset({
    "missing_key", "no_lanes", "file_count_unmeasured", "endpoint_refused",
    "invalid_response", "answer_missing", "no_lane_match", "service_error",
})
MAX_RESPONSE = 65536
MAX_EVIDENCE_TEXT = 128
MIN_WIRE_PROBABILITY_BYTES = len('"o1":0')
MAX_LOG_PROBABILITY_BYTES = 2 * MAX_EVIDENCE_TEXT + len('"":,') + 24
# Allow for escaped local lane IDs replacing short wire IDs and for the map
# appearing both at the top level and under answers.lane.
MAX_RECOMMENDATION_BYTES = 4096 + 2 * (MAX_RESPONSE // MIN_WIRE_PROBABILITY_BYTES) * MAX_LOG_PROBABILITY_BYTES

SECRET_SHAPE = re.compile(
    r"(?<![A-Za-z0-9])(sk|pk|ghp|gho|ghs|ghu|ghr|xox[abprs]|glpat)[-_][A-Za-z0-9_-]{8,}"
    r"|github_pat_[A-Za-z0-9_]{8,}|AKIA[0-9A-Z]{12,}|AIza[0-9A-Za-z_-]{20,}"
    r"|eyJ[A-Za-z0-9_-]{8,}[.]|bearer[ ]"
    r"|(token|secret|passwd|password|api[_-]?key|credential)[=:]"
    r"|(?<![A-Za-z0-9_+/])(?!(?:[0-9a-f]{40}|[0-9a-f]{64})(?![A-Za-z0-9_+/]))[A-Za-z0-9_+/]{32,}",
    re.IGNORECASE)


URL_USERINFO = re.compile(r"((?<![\w+.-])[A-Za-z][A-Za-z0-9+.-]*://|(?<![\w/:])//)\S*@")
EMAIL_LOCAL_CHAR = r"[\w.!#$%&'*+/=?^`{|}~-]"
EMAIL_ADDRESS = re.compile(rf"(?<!{EMAIL_LOCAL_CHAR}){EMAIL_LOCAL_CHAR}+@[\w-]+(?:\.[\w-]+)+")


def recordable_text(value, secret=None):
    return isinstance(value, str) and 1 <= len(value) <= MAX_EVIDENCE_TEXT and re.fullmatch(r"[!-~]+", value) is not None \
        and not (secret and secret in value) and SECRET_SHAPE.search(value) is None \
        and URL_USERINFO.search(value) is None and EMAIL_ADDRESS.search(value) is None


def recordable_reason(value, secret=None):
    return isinstance(value, str) and value in UNAVAILABLE_REASONS and recordable_text(value, secret)


def unit_interval(value):
    return type(value) in (int, float) and 0 <= value <= 1


def recordable_probability(name, score, secret=None):
    return recordable_text(name, secret) and unit_interval(score)


def recordable_probabilities(value, secret=None):
    if not isinstance(value, dict):
        return {}
    return {name: score for name, score in value.items() if recordable_probability(name, score, secret)}


def recordable_answer(answer, secret=None):
    """The bounded per-question fields a recommendation answer may record, or None."""
    if not isinstance(answer, dict):
        return None
    entry = {}
    kind = answer.get("type")
    if recordable_text(kind, secret) and re.fullmatch(r"[a-z]{1,32}", kind):
        entry["type"] = kind
    if "choice" in answer and recordable_text(answer["choice"], secret):
        entry["choice"] = answer["choice"]
    if "answer" in answer and (isinstance(answer["answer"], bool) or answer["answer"] is None):
        entry["answer"] = answer["answer"]
    if "confidence" in answer and unit_interval(answer["confidence"]):
        entry["confidence"] = answer["confidence"]
    if "probabilities" in answer:
        kept = recordable_probabilities(answer["probabilities"], secret)
        if kept:
            entry["probabilities"] = kept
    return entry
