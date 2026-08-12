#!/usr/bin/env python3
"""Local Telegram bridge that implements the Squad Relay connector contract.

This is the "local relay" the Squad base's SQX_RELAY_URL can point at
(docs/configuration.md, "Relay (.env)").  It implements the connector contract
exactly - the same GET /connector/poll and POST /connector/{answer,dismiss,
followup,request-context} endpoints the shared mySquad.io relay exposes - and
translates them to and from the Telegram Bot API.  Zero Squad core changes:
the base's .env only points SQX_RELAY_URL at this bridge, and the bridge
authenticates connector calls with the same SQX_PAIRING_TOKEN.

Contract this bridge implements (single owner of the wire shape is the Relay
section of docs/configuration.md; this header records only the bridge's own
behavior):

  GET  /connector/poll            -> 200 {"request_id","text","platform",
                                       "reply_max_chars","in_reply_to"}
                                     for the oldest pending request (which stays
                                     pending and is re-offered until answered or
                                     dismissed, like the shared relay), 204 when
                                     nothing is pending.
  POST /connector/answer          -> {request_id,text} or {request_id,text,texts}
                                     (plus optional {image:{media_type,
                                     data_base64}} on the opener).  Sends the
                                     reply into the Telegram chat as a chained
                                     numbered thread, binds the request for
                                     follow-ups, then returns 2xx.  Re-answer of
                                     an already answered request is an idempotent
                                     2xx that sends nothing; an unknown request
                                     is 404; a Telegram failure is 502 and leaves
                                     the request pending for the client to retry.
  POST /connector/dismiss         -> {request_id}; drops a pending request
                                     without posting.  Idempotent 2xx.
  POST /connector/followup        -> same body shape as answer; accepted only
                                     against an answered binding inside the
                                     7-day window and under the 3-post cap.
                                     Exhausted/unknown -> 409
                                     {"error":"followup_unavailable"} (the exact
                                     rejection the Squad client maps to exit 9).
  POST /connector/request-context -> {request_id} -> 200 {"platform",
                                     "reply_max_chars"} for a known request,
                                     404 for an unknown one.

Platform/budget: the poll payload reports platform "discord" with an explicit
reply_max_chars of 4096.  The Squad client resolves only the "x" and "discord"
platforms for its follow-up fail-safe (bin/sq-x-lib.sh
fmx_resolve_reply_context), and an explicit limit always wins over the platform
default, so Telegram replies split at Telegram's 4096-character message budget
while follow-ups still pass the client's fail-safe.  This is a deliberate
compatibility choice, not a lie that leaks anywhere user-facing: the platform
value only selects the split-budget default when no explicit limit is known.

Telegram side (long-poll, no public HTTPS needed):
  - getUpdates long-polling with a persisted offset, so restarts re-fetch
    nothing and never duplicate a request (the offset and the request store
    both live in the state file).
  - Only messages whose sender user id is in TG_ALLOWED_CHAT_IDS become
    requests; everyone else is ignored (a private bot that never answers
    strangers).
  - A /start from an allowed user gets a one-line greeting and no request.
  - Text-less messages (no text and no caption) are ignored: the Squad poll
    client only wakes on non-empty text.
  - request_id is the stable "tg-<chat_id>-<message_id>" slug, so re-offers
    after a restart dedupe on the same id.
  - Outbound replies are chained Telegram replies: the first message replies to
    the commander's original message, every later chunk replies to the
    previously sent message, so a numbered thread stays visually grouped.
  - An optional image object on an answer/follow-up is sent as a sendPhoto
    (multipart upload); the text chunks then follow as chained messages.

Security: the connector binds to 127.0.0.1 by default and every connector call
must present the exact SQX_PAIRING_TOKEN (constant-time compare).  The bridge
refuses to start without that token, without a bot token, or without at least
one allowed chat id: all three are fail-closed.  The runtime state file is
written atomically with mode 0600 under a 0700 directory and the bridge refuses
a symlinked state file.

Config (env wins over file; file wins over default):
  SQUAD_HOME                 base home for .env and config lookups
                             (default: this repo root; same resolution as the
                             sq-x-* client scripts)
  <SQUAD_HOME>/.env          SQX_PAIRING_TOKEN (shared with the Squad base)
  <SQUAD_HOME>/config/telegram-bridge.env   TG_BOT_TOKEN, TG_ALLOWED_CHAT_IDS,
                             TG_BRIDGE_BIND, TG_BRIDGE_PORT
  TG_BOT_TOKEN               Telegram bot token from @BotFather (required)
  TG_ALLOWED_CHAT_IDS        comma-separated Telegram user ids allowed to send
                             requests (required; the commander's user id)
  TG_BRIDGE_BIND             connector listen address (default 127.0.0.1)
  TG_BRIDGE_PORT             connector listen port (default 8787; 0 = ephemeral)
  TG_BRIDGE_CONFIG           alternate bridge env file
  TG_BRIDGE_STATE_FILE       alternate runtime state file (default
                             <SQUAD_HOME>/state/telegram-bridge/state.json)
  TG_BRIDGE_NOW_OVERRIDE     test seam: epoch seconds replacing the wall clock
                             for follow-up window math (same role as
                             SQX_NOW_OVERRIDE in bin/sq-x-lib.sh)

Usage: sq-tg-bridge.py [--help] [--config FILE] [--bind ADDR] [--port N]
                       [--telegram-api-url URL] [--state-file FILE]

--telegram-api-url overrides the Bot API base (default https://api.telegram.org)
and exists so tests can point the bridge at a fake Telegram server; real
deployments never need it.

Run `bin/sq-tg-bridge.py --help` for the full flag list.
"""
import argparse
import base64
import hmac
import http.client
import http.server
import json
import os
import secrets
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

FOLLOWUP_WINDOW_SECS = 7 * 24 * 3600   # contract: 7-day follow-up window
FOLLOWUP_MAX_COUNT = 3                # contract: at most 3 follow-ups per link
PLATFORM = "discord"                  # see header: client-resolved platform
REPLY_MAX_CHARS = 4096                # Telegram's per-message character budget
MAX_BODY_BYTES = 64 * 1024 * 1024     # connector POST body cap (image base64)
GETUPDATES_TIMEOUT = 30               # Telegram long-poll seconds
HTTP_TIMEOUT = 35                     # outbound HTTP cap (long-poll + margin)


def log(msg):
    print("[sq-tg-bridge] %s %s" % (
        time.strftime("%Y-%m-%dT%H:%M:%S%z"), msg), file=sys.stderr, flush=True)


def load_env_file(path):
    """Parse a simple KEY=VALUE env file into a dict (comments and quotes ok).

    Missing or unreadable files yield an empty dict; malformed lines are
    skipped.  This intentionally mirrors the loose KEY=VALUE parsing the
    sq-x-* client scripts already apply to .env files.
    """
    out = {}
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                if line.startswith("export "):
                    line = line[len("export "):].strip()
                key, _, value = line.partition("=")
                key = key.strip()
                value = value.strip()
                if not key:
                    continue
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                out[key] = value
    except OSError:
        return {}
    return out


def first_set(primary, *fallbacks):
    for src in fallbacks:
        if primary is None:
            primary = src
    return primary


class BridgeConfig:
    """Resolve every setting: CLI flag > env var > env file > default."""

    def __init__(self, args):
        script_dir = os.path.dirname(os.path.abspath(__file__))
        self.squad_home = os.environ.get("SQUAD_HOME") or os.path.dirname(script_dir)
        base_env = load_env_file(os.path.join(self.squad_home, ".env"))
        bridge_file = args.config or os.environ.get("TG_BRIDGE_CONFIG") \
            or os.path.join(self.squad_home, "config", "telegram-bridge.env")
        bridge_env = load_env_file(bridge_file)

        self.token = first_set(
            os.environ.get("SQX_PAIRING_TOKEN"),
            base_env.get("SQX_PAIRING_TOKEN"))
        self.bot_token = first_set(
            os.environ.get("TG_BOT_TOKEN"), bridge_env.get("TG_BOT_TOKEN"))
        allowed = first_set(
            os.environ.get("TG_ALLOWED_CHAT_IDS"),
            bridge_env.get("TG_ALLOWED_CHAT_IDS"))
        self.allowed_chat_ids = set()
        for raw in (allowed or "").split(","):
            raw = raw.strip()
            if not raw:
                continue
            try:
                self.allowed_chat_ids.add(int(raw))
            except ValueError:
                self.allowed_chat_ids.add(raw)  # let the strict check below fail
        self.bind = first_set(
            args.bind, os.environ.get("TG_BRIDGE_BIND"),
            bridge_env.get("TG_BRIDGE_BIND"), "127.0.0.1")
        port = first_set(
            args.port, os.environ.get("TG_BRIDGE_PORT"),
            bridge_env.get("TG_BRIDGE_PORT"), "8787")
        try:
            self.port = int(port)
        except ValueError:
            raise SystemExit("sq-tg-bridge: invalid TG_BRIDGE_PORT: %r" % port)
        self.state_file = first_set(
            args.state_file, os.environ.get("TG_BRIDGE_STATE_FILE"),
            os.path.join(self.squad_home, "state", "telegram-bridge",
                         "state.json"))
        self.api_url = args.telegram_api_url or "https://api.telegram.org"
        self.now_override = os.environ.get("TG_BRIDGE_NOW_OVERRIDE")
        if self.now_override is not None:
            try:
                self.now_override = int(self.now_override)
            except ValueError:
                raise SystemExit(
                    "sq-tg-bridge: invalid TG_BRIDGE_NOW_OVERRIDE: %r"
                    % self.now_override)
        self._validate()

    def _validate(self):
        missing = []
        if not self.token:
            missing.append("SQX_PAIRING_TOKEN (from the base's .env or env)")
        if not self.bot_token:
            missing.append("TG_BOT_TOKEN")
        if not self.allowed_chat_ids:
            missing.append("TG_ALLOWED_CHAT_IDS")
        elif not all(isinstance(cid, int) for cid in self.allowed_chat_ids):
            missing.append("TG_ALLOWED_CHAT_IDS (must be comma-separated "
                           "numeric Telegram user ids)")
        if not (0 <= self.port <= 65535):
            missing.append("TG_BRIDGE_PORT (must be 0-65535)")
        if missing:
            raise SystemExit(
                "sq-tg-bridge: refusing to start, missing or invalid config: "
                + "; ".join(missing))
        if os.path.islink(self.state_file):
            raise SystemExit(
                "sq-tg-bridge: refusing a symlinked state file: %s"
                % self.state_file)
        if self.now_override is not None and self.now_override <= 0:
            raise SystemExit(
                "sq-tg-bridge: invalid TG_BRIDGE_NOW_OVERRIDE: %r"
                % self.now_override)

    def now(self):
        if self.now_override is not None:
            return self.now_override
        return int(time.time())


class RequestStore:
    """Thread-safe request + binding store, persisted atomically as JSON.

    One record per request_id:
      {chat_id, message_id, text, in_reply_to, created_at,
       status: "pending"|"answered", answered_at, followups}
    Dismissed requests are removed outright (no follow-up can ever come).
    Answered requests stay until the follow-up window lapses, then are pruned.
    """

    def __init__(self, path, now_fn, log_fn):
        self.path = path
        self.now_fn = now_fn
        self.log = log_fn
        self.lock = threading.Lock()
        self._locks = {}
        self.offset = 0
        self.requests = {}
        self._load()

    def _load(self):
        try:
            with open(self.path, encoding="utf-8") as fh:
                data = json.load(fh)
            self.offset = int(data.get("offset") or 0)
            for rid, rec in (data.get("requests") or {}).items():
                if isinstance(rid, str) and isinstance(rec, dict) \
                        and rec.get("status") in ("pending", "answered") \
                        and isinstance(rec.get("chat_id"), int) \
                        and isinstance(rec.get("message_id"), int):
                    self.requests[rid] = rec
        except FileNotFoundError:
            pass
        except (OSError, ValueError, TypeError, json.JSONDecodeError,
                AttributeError) as exc:
            self.log("state file %s unreadable (%s); starting empty"
                     % (self.path, exc))
            self.offset = 0
            self.requests = {}
        self.prune()

    def _save(self):
        directory = os.path.dirname(self.path)
        try:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        except OSError as exc:
            self.log("cannot create state directory %s: %s"
                     % (directory, exc))
            return False
        try:
            os.chmod(directory, 0o700)
        except OSError:
            pass
        tmp = "%s.tmp.%s" % (self.path, secrets.token_hex(6))
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as fh:
                json.dump({"offset": self.offset, "requests": self.requests},
                          fh, ensure_ascii=False, sort_keys=True)
            os.replace(tmp, self.path)
            return True
        except OSError as exc:
            self.log("cannot persist state %s: %s" % (self.path, exc))
            try:
                os.unlink(tmp)
            except OSError:
                pass
            return False

    def prune(self):
        """Drop answered bindings whose follow-up window has lapsed."""
        now = self.now_fn()
        with self.lock:
            expired = [rid for rid, rec in self.requests.items()
                       if rec.get("status") == "answered"
                       and isinstance(rec.get("answered_at"), int)
                       and now - rec["answered_at"] >= FOLLOWUP_WINDOW_SECS]
            for rid in expired:
                del self.requests[rid]
            if expired:
                self._save()

    def get(self, rid):
        with self.lock:
            return self.requests.get(rid)

    def lock_for(self, rid):
        with self.lock:
            lk = self._locks.get(rid)
            if lk is None:
                lk = threading.Lock()
                self._locks[rid] = lk
            return lk

    def pending_ids(self):
        with self.lock:
            pending = [rid for rid, rec in self.requests.items()
                       if rec.get("status") == "pending"]
            pending.sort(key=lambda rid: (self.requests[rid].get("created_at", 0),
                                          self.requests[rid].get("message_id", 0)))
            return pending

    def add(self, rid, rec):
        with self.lock:
            if rid in self.requests:
                return False
            self.requests[rid] = rec
            return self._save()

    def mark_answered(self, rid, at):
        with self.lock:
            rec = self.requests.get(rid)
            if rec is None:
                return False
            rec["status"] = "answered"
            rec["answered_at"] = at
            rec["followups"] = 0
            return self._save()

    def bump_followups(self, rid):
        with self.lock:
            rec = self.requests.get(rid)
            if rec is None:
                return False
            rec["followups"] = int(rec.get("followups") or 0) + 1
            return self._save()

    def remove(self, rid):
        with self.lock:
            if rid not in self.requests:
                return False
            del self.requests[rid]
            return self._save()

    def set_offset(self, offset):
        with self.lock:
            if offset <= self.offset:
                return False
            self.offset = offset
            return self._save()


class TelegramError(Exception):
    def __init__(self, code, description):
        super().__init__("%s: %s" % (code, description))
        self.code = code
        self.description = description


class TelegramClient:
    """Minimal Bot API client: getUpdates, sendMessage, sendPhoto."""

    def __init__(self, api_url, bot_token, log_fn):
        self.base = "%s/bot%s" % (api_url.rstrip("/"), bot_token)
        self.log = log_fn

    def call_json(self, method, params):
        url = "%s/%s" % (self.base, method)
        data = json.dumps(params).encode("utf-8")
        req = urllib.request.Request(url, data=data, method="POST",
                                     headers={"Content-Type": "application/json"})
        return self._open(req)

    def call_form(self, method, fields, files):
        boundary = "----sqtg%s" % secrets.token_hex(12)
        body = bytearray()
        for name, value in fields:
            body.extend(("--%s\r\nContent-Disposition: form-data; "
                         'name="%s"\r\n\r\n%s\r\n' % (boundary, name, value))
                        .encode("utf-8"))
        for name, filename, ctype, data in files:
            body.extend(("--%s\r\nContent-Disposition: form-data; "
                         'name="%s"; filename="%s"\r\nContent-Type: %s\r\n'
                         "\r\n" % (boundary, name, filename, ctype))
                        .encode("utf-8"))
            body.extend(data)
            body.extend(b"\r\n")
        body.extend(("--%s--\r\n" % boundary).encode("utf-8"))
        url = "%s/%s" % (self.base, method)
        req = urllib.request.Request(url, data=bytes(body), method="POST",
                                     headers={
                                         "Content-Type":
                                             "multipart/form-data; boundary=%s"
                                             % boundary})
        return self._open(req)

    def _open(self, req):
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT) as resp:
                payload = json.loads(resp.read().decode("utf-8"))
        except urllib.error.HTTPError as exc:
            try:
                detail = exc.read().decode("utf-8", "replace")
            except (OSError, http.client.HTTPException) as read_exc:
                detail = "error body unreadable: %s" % read_exc
            raise TelegramError(exc.code, detail) from exc
        except urllib.error.URLError as exc:
            raise TelegramError("network", str(exc.reason)) from exc
        except OSError as exc:
            raise TelegramError("network", str(exc)) from exc
        except ValueError as exc:
            raise TelegramError("api", "malformed response: %s" % exc) from exc
        except http.client.HTTPException as exc:
            raise TelegramError("network", "truncated response: %s" % exc) from exc
        if not isinstance(payload, dict):
            raise TelegramError("api", "malformed response: not an object")
        if not payload.get("ok"):
            raise TelegramError(payload.get("error_code", "api"),
                                payload.get("description", "unknown error"))
        return payload.get("result")

    def get_updates(self, offset, timeout=GETUPDATES_TIMEOUT):
        """Long-poll one getUpdates round; returns the result list."""
        params = urllib.parse.urlencode({
            "offset": offset, "timeout": timeout,
            "allowed_updates": json.dumps(["message"])})
        url = "%s/getUpdates?%s" % (self.base, params)
        req = urllib.request.Request(url, method="GET")
        result = self._open(req)
        return result if isinstance(result, list) else []

    def send_message(self, chat_id, text, reply_to_message_id=None):
        params = {"chat_id": chat_id, "text": text}
        if reply_to_message_id is not None:
            params["reply_to_message_id"] = reply_to_message_id
        return self.call_json("sendMessage", params)

    def send_photo(self, chat_id, data, media_type, reply_to_message_id=None):
        fields = [("chat_id", str(chat_id))]
        if reply_to_message_id is not None:
            fields.append(("reply_to_message_id", str(reply_to_message_id)))
        ext = {  # pragma: no cover - cosmetic filename only
            "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
            "image/webp": "webp", "image/bmp": "bmp", "image/tiff": "tiff",
        }.get(media_type, "img")
        return self.call_form("sendPhoto", fields,
                              [("photo", "photo.%s" % ext, media_type, data)])


def safe_slug(rid):
    """The same request_id guard the Squad poll client applies."""
    if not rid or rid.startswith("."):
        return False
    return all(ch in "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
               "0123456789._-" for ch in rid)


class ConnectorHandler(http.server.BaseHTTPRequestHandler):
    server_version = "SquadTelegramBridge/1"

    def log_message(self, fmt, *args):  # suppress per-request access logs
        pass

    # --- plumbing ----------------------------------------------------------

    def _authorized(self):
        header = self.headers.get("Authorization", "")
        scheme, _, value = header.partition(" ")
        if scheme.lower() != "bearer" or not value:
            return False
        return hmac.compare_digest(value, self.server.bridge.config.token)

    def _deny(self, code):
        self.send_response(code)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def _json(self, code, obj):
        body = json.dumps(obj).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_BODY_BYTES:
            return None
        return self.rfile.read(length)

    def _body_json(self):
        raw = self._read_body()
        if raw is None:
            return None
        try:
            obj = json.loads(raw.decode("utf-8"))
        except (ValueError, UnicodeDecodeError):
            return None
        return obj if isinstance(obj, dict) else None

    # --- Telegram outbound --------------------------------------------------

    def _send_thread(self, chat_id, chunks, image, reply_to_id):
        """Send one image plus ordered chunks as a chained thread.

        Returns the message_id of the last sent message.  Raises
        TelegramError on the first failure; earlier messages of a partial
        thread may already be posted (the caller keeps the request pending so
        the client retries, which can duplicate those early chunks - bounded
        and rare, documented in the header).
        """
        last_id = reply_to_id
        if image is not None:
            result = self.server.bridge.tg.send_photo(
                chat_id, image["data"], image["media_type"], last_id)
            last_id = self._sent_message_id(result, "sendPhoto")
        for chunk in chunks:
            result = self.server.bridge.tg.send_message(
                chat_id, chunk, last_id)
            last_id = self._sent_message_id(result, "sendMessage")
        return last_id

    @staticmethod
    def _sent_message_id(result, method):
        if not isinstance(result, dict) or not isinstance(
                result.get("message_id"), int):
            raise TelegramError("api", "malformed %s result" % method)
        return result["message_id"]

    def _decode_image(self, image):
        if not isinstance(image, dict):
            return None
        media_type = image.get("media_type")
        raw = image.get("data_base64")
        if not isinstance(media_type, str) or not isinstance(raw, str):
            return None
        try:
            data = base64.b64decode(raw, validate=True)
        except (ValueError, TypeError):
            return None
        if not data:
            return None
        return {"media_type": media_type, "data": data}

    # --- routes --------------------------------------------------------------

    def do_GET(self):
        if self.path.rstrip("/") != "/connector/poll":
            self._deny(404)
            return
        if not self._authorized():
            self._deny(401)
            return
        bridge = self.server.bridge
        pending = bridge.store.pending_ids()
        if not pending:
            self._deny(204)
            return
        rid = pending[0]
        rec = bridge.store.get(rid)
        if rec is None:
            self._deny(204)
            return
        self._json(200, {
            "request_id": rid,
            "text": rec.get("text", ""),
            "platform": PLATFORM,
            "reply_max_chars": REPLY_MAX_CHARS,
            "in_reply_to": rec.get("in_reply_to"),
        })

    def do_POST(self):
        path = self.path.rstrip("/")
        if path not in ("/connector/answer", "/connector/dismiss",
                        "/connector/followup", "/connector/request-context"):
            self._deny(404)
            return
        if not self._authorized():
            self._deny(401)
            return
        body = self._body_json()
        if body is None:
            self._json(400, {"error": "invalid_json"})
            return
        rid = body.get("request_id")
        if not isinstance(rid, str) or not safe_slug(rid):
            self._json(404, {"error": "unknown_request"})
            return
        bridge = self.server.bridge
        rec = bridge.store.get(rid)
        if path == "/connector/request-context":
            if rec is None:
                self._deny(404)
                return
            self._json(200, {"platform": PLATFORM,
                             "reply_max_chars": REPLY_MAX_CHARS})
            return
        if path == "/connector/dismiss":
            with bridge.store.lock_for(rid):
                if bridge.store.remove(rid):
                    bridge.log("dismissed %s" % rid)
            self._deny(200)
            return
        with bridge.store.lock_for(rid):
            rec = bridge.store.get(rid)
            if path == "/connector/followup":
                binding_ok = (rec is not None
                              and rec.get("status") == "answered"
                              and isinstance(rec.get("answered_at"), int)
                              and bridge.config.now() - rec["answered_at"]
                                  < FOLLOWUP_WINDOW_SECS
                              and int(rec.get("followups") or 0)
                                  < FOLLOWUP_MAX_COUNT)
                if not binding_ok:
                    self._json(409, {"error": "followup_unavailable"})
                    return
            elif rec is None:
                self._json(404, {"error": "unknown_request"})
                return
            elif rec.get("status") == "answered":
                self._deny(200)  # idempotent re-answer: already posted, send nothing
                return
            chunks = body.get("texts")
            if not isinstance(chunks, list) \
                    or not all(isinstance(c, str) and c for c in chunks):
                text = body.get("text")
                chunks = [text] if isinstance(text, str) and text else []
            if not chunks:
                self._json(400, {"error": "empty_text"})
                return
            image = self._decode_image(body.get("image"))
            try:
                self._send_thread(rec["chat_id"], chunks, image,
                                  rec["message_id"])
            except TelegramError as exc:
                bridge.log("telegram send failed for %s: %s" % (rid, exc))
                self._json(502, {"error": "telegram_send_failed",
                                 "detail": "%s: %s" % (exc.code,
                                                       exc.description)})
                return
            if path == "/connector/followup":
                bridge.store.bump_followups(rid)
                bridge.log("follow-up %d/3 posted for %s" % (
                    int(rec.get("followups") or 0) + 1, rid))
            else:
                bridge.store.mark_answered(rid, bridge.config.now())
                bridge.log("answered %s" % rid)
            self._deny(200)


class Bridge:
    def __init__(self, config):
        self.config = config
        self.log = log
        self.store = RequestStore(config.state_file, config.now, log)
        self.tg = TelegramClient(config.api_url, config.bot_token, log)

    def handle_telegram_update(self, update):
        """Classify one getUpdates result element; returns the request_id or
        None.  Exposed as one method so the ingest rules are testable as a
        unit and the poll loop stays a thin driver."""
        if not isinstance(update, dict):
            return None
        update_id = update.get("update_id")
        if isinstance(update_id, int) and update_id <= self.store.offset:
            return None
        message = update.get("message")
        if not isinstance(message, dict):
            return None
        sender = message.get("from")
        chat = message.get("chat")
        if not isinstance(sender, dict) or not isinstance(chat, dict):
            return None
        user_id = sender.get("id")
        chat_id = chat.get("id")
        if user_id not in self.config.allowed_chat_ids:
            log("ignoring message from non-whitelisted user %r" % (user_id,))
            return None
        text = (message.get("text") or message.get("caption") or "").strip()
        if not text:
            return None
        if text == "/start" or text.startswith("/start@"):
            try:
                self.tg.send_message(chat_id,
                                     "Squad bridge online. "
                                     "Messages here reach the commander's Squad.")
            except TelegramError as exc:
                log("greeting send failed for chat %s: %s" % (chat_id, exc))
            return None
        message_id = message.get("message_id")
        if not isinstance(message_id, int):
            return None
        rid = "tg-%s-%s" % (chat_id, message_id)
        if self.store.get(rid) is not None:
            return None  # already ingested (restart replay / dedupe)
        in_reply_to = None
        parent = message.get("reply_to_message")
        if isinstance(parent, dict):
            author = parent.get("from")
            handle = "unknown"
            if isinstance(author, dict):
                handle = (author.get("username")
                          or author.get("first_name") or handle)
            parent_text = (parent.get("text")
                           or parent.get("caption") or "")
            in_reply_to = {"author_handle": handle, "text": parent_text}
        record = {
            "chat_id": chat_id,
            "message_id": message_id,
            "text": text,
            "in_reply_to": in_reply_to,
            "created_at": self.config.now(),
            "status": "pending",
            "answered_at": None,
            "followups": 0,
        }
        if self.store.add(rid, record):
            log("ingested %s" % rid)
            return rid
        return None

    def telegram_loop(self, stop_event):
        offset = self.store.offset
        backoff = 1
        while not stop_event.is_set():
            try:
                result = self.tg.get_updates(offset + 1)
                backoff = 1
            except TelegramError as exc:
                log("getUpdates failed (%s); backing off %ds"
                    % (exc, backoff))
                stop_event.wait(backoff)
                backoff = min(backoff * 2, 60)
                continue
            except OSError as exc:
                log("getUpdates network error (%s); backing off %ds"
                    % (exc, backoff))
                stop_event.wait(backoff)
                backoff = min(backoff * 2, 60)
                continue
            for update in result or []:
                if not isinstance(update, dict):
                    continue
                self.handle_telegram_update(update)
                update_id = update.get("update_id")
                if isinstance(update_id, int) and update_id > offset:
                    offset = update_id
            if offset > self.store.offset:
                self.store.set_offset(offset)
            self.store.prune()


def build_arg_parser():
    parser = argparse.ArgumentParser(
        prog="sq-tg-bridge.py",
        description="Local Telegram bridge implementing the Squad Relay "
                    "connector contract (see the script header).")
    parser.add_argument("--config", metavar="FILE",
                        help="bridge env file (default: "
                             "<SQUAD_HOME>/config/telegram-bridge.env)")
    parser.add_argument("--bind", metavar="ADDR",
                        help="connector listen address (default 127.0.0.1)")
    parser.add_argument("--port", metavar="N",
                        help="connector listen port (default 8787; 0 picks "
                             "an ephemeral port)")
    parser.add_argument("--telegram-api-url", metavar="URL",
                        help="Bot API base URL override, mainly for tests "
                             "(default https://api.telegram.org)")
    parser.add_argument("--state-file", metavar="FILE",
                        help="runtime state file (default "
                             "<SQUAD_HOME>/state/telegram-bridge/state.json)")
    return parser


def main(argv=None):
    args = build_arg_parser().parse_args(argv)
    try:
        config = BridgeConfig(args)
    except SystemExit as exc:
        if exc.code:
            print(str(exc.code), file=sys.stderr)
        raise
    bridge = Bridge(config)
    handler = lambda *hargs, **hkwargs: ConnectorHandler(*hargs, **hkwargs)
    try:
        server = http.server.ThreadingHTTPServer((config.bind, config.port),
                                                  handler)
    except OSError as exc:
        raise SystemExit("sq-tg-bridge: cannot listen on %s:%s: %s"
                         % (config.bind, config.port, exc))
    server.bridge = bridge
    host, port = server.server_address[:2]
    log("listening on http://%s:%s (telegram api %s, state %s)"
        % (host, port, config.api_url, config.state_file))
    log("whitelisted senders: %s"
        % ", ".join(str(cid) for cid in sorted(config.allowed_chat_ids)))
    stop_event = threading.Event()
    poller = threading.Thread(target=bridge.telegram_loop,
                              args=(stop_event,), daemon=True)
    poller.start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("interrupted, shutting down")
    finally:
        stop_event.set()
        server.server_close()


if __name__ == "__main__":
    main()
