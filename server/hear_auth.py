# -*- coding: utf-8 -*-
"""Hear 网关的托管访问口令校验（只用 Python 标准库）。

网关启动时从 Token 管理服务拉取本实例的完整 Token 清单，之后每 30 秒整体替换一次。
推理请求只在内存里比对 SHA-256 摘要和时间，不访问数据库，也不调用管理服务。
每个 Token 的限流（每分钟请求数、同时请求数）也只在内存里执行；识别时长额度按
「管理服务上已记录的用量 + 本网关还没上报的用量」判断，用量每 30 秒批量上报一次。

环境变量：
    HEAR_AUTH_MODE                 managed（托管）/ legacy（旧的单口令）/ off
    HEAR_AUTH_API_URL              Token 管理服务地址，例如 https://10.0.0.5:8443
    HEAR_GATEWAY_ID                本网关 ID，例如 hear-home
    HEAR_GATEWAY_CREDENTIAL_FILE   网关凭据文件（只放路径，凭据本身不进命令行和脚本）
    HEAR_AUTH_CA_FILE              可选：管理服务使用自签证书时，信任这个 CA / 证书文件
"""
import datetime
import hashlib
import collections
import math
import secrets
import http.client
import ipaddress
import json
import os
import re
import ssl
import threading
import time
import urllib.error
import urllib.request
from urllib.parse import quote, urlsplit

REFRESH_INTERVAL = 30.0
MAX_STALENESS = 60.0
RETRY_INTERVAL = 5.0
MAX_SNAPSHOT_BYTES = 32 * 1024 * 1024
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")
USAGE_BUCKET_US = 15 * 60 * 1000000
USAGE_KEEP_US = 40 * 86400 * 1000000
MAX_USAGE_BATCH = 300
LIMIT_KEYS = ("rate_per_minute", "max_concurrent", "daily_audio_minutes", "monthly_audio_minutes")

MESSAGES = {
    "TOKEN_REQUIRED": "请填写访问口令",
    "TOKEN_INVALID": "访问口令无效，请核对",
    "TOKEN_NOT_STARTED": "访问口令尚未生效",
    "TOKEN_EXPIRED": "访问口令已到期",
    "TOKEN_REVOKED": "访问口令已被撤销，请联系管理员",
    "AUTH_SERVICE_UNAVAILABLE": "已连到服务，口令管理暂不可用",
    "HTTPS_REQUIRED": "请求未使用 HTTPS，已拒绝",
    "RATE_LIMITED": "请求太频繁，请稍后再试",
    "CONCURRENCY_LIMITED": "同时进行的请求太多，请稍后再试",
    "QUOTA_EXCEEDED": "识别时长额度已用完",
}


class AuthConfigError(Exception):
    """管理模式配置不完整或不合法。"""


class SnapshotError(Exception):
    """清单内容不合规则，本次同步算失败。"""


# ------------------------------------------------------------------ 时间

def parse_time(value):
    """带时区的 ISO 8601 → UTC 微秒整数。没有时区的时间不接受。"""
    if not isinstance(value, str) or not value:
        raise ValueError("time must be a non-empty string")
    text = value.strip()
    if text.endswith(("Z", "z")):
        text = text[:-1] + "+00:00"
    parsed = datetime.datetime.fromisoformat(text)
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("time must include a timezone")
    delta = parsed - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
    return (delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds


def format_time(us):
    if us is None:
        return None
    moment = datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc) + datetime.timedelta(microseconds=us)
    if moment.microsecond:
        return moment.strftime("%Y-%m-%dT%H:%M:%S.%fZ")
    return moment.strftime("%Y-%m-%dT%H:%M:%SZ")


def now_us(wall=time.time):
    return int(wall() * 1000000)


def token_digest(token):
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


# ------------------------------------------------------------------ 结果

class AuthResult:
    __slots__ = ("ok", "http_status", "code", "message", "details", "subject", "limits")

    def __init__(self, ok, http_status=200, code=None, message=None, details=None):
        self.ok = ok
        self.http_status = http_status
        self.code = code
        self.message = message
        self.details = details or {}
        # 托管模式下通过校验的 Token：token_id 和它的限流额度（不返回给客户端）
        self.subject = None
        self.limits = {}

    @classmethod
    def allow(cls, details=None):
        return cls(True, 200, None, None, details)

    @classmethod
    def deny(cls, code, http_status=401, details=None, message=None):
        return cls(False, http_status, code, message or MESSAGES[code], details)


def describe(entry, now):
    """把一条清单记录换算成状态和时间（与管理后台使用同一套规则）。"""
    starts, expires, revoked = entry["starts_at"], entry["expires_at"], entry["revoked_at"]
    if revoked is not None and revoked < expires:
        # 撤销记录一律按撤销处理，哪怕两边时钟有偏差、撤销时间略晚于本机时间
        status, effective, invalidated = "revoked", revoked, revoked
    elif now >= expires:
        status, effective, invalidated = "expired", expires, expires
    elif now < starts:
        status, effective, invalidated = "scheduled", expires, None
    else:
        status, effective, invalidated = "active", expires, None
    return {
        "status": status,
        "starts_at": format_time(starts),
        "expires_at": format_time(expires),
        "effective_expires_at": format_time(effective),
        "invalidated_at": format_time(invalidated),
    }


# ------------------------------------------------------------------ 清单解析

def parse_snapshot(raw, gateway_id):
    """校验结构、时间、摘要、绑定关系。返回 (revision, {sha256: entry})。"""
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise SnapshotError("清单不是有效的 JSON") from error
    if not isinstance(data, dict):
        raise SnapshotError("清单格式不对")
    if data.get("gateway_id") != gateway_id:
        raise SnapshotError("清单不属于本网关")
    if data.get("digest_algorithm") != "sha256":
        raise SnapshotError("不支持的摘要算法")
    revision = data.get("revision")
    if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
        raise SnapshotError("修订号不合法")
    try:
        parse_time(data.get("generated_at"))
    except (TypeError, ValueError) as error:
        raise SnapshotError("generated_at 不合法") from error
    tokens = data.get("tokens")
    if not isinstance(tokens, list):
        raise SnapshotError("tokens 不是列表")
    entries = {}
    for item in tokens:
        if not isinstance(item, dict):
            raise SnapshotError("Token 记录格式不对")
        digest = item.get("sha256")
        if not isinstance(digest, str) or not DIGEST_RE.match(digest):
            raise SnapshotError("摘要格式不对")
        if digest in entries:
            raise SnapshotError("摘要重复")
        token_id, user_id = item.get("token_id"), item.get("user_id")
        if not (isinstance(token_id, str) and ID_RE.match(token_id)
                and isinstance(user_id, str) and ID_RE.match(user_id)):
            raise SnapshotError("Token 或用户 ID 不合法")
        try:
            starts = parse_time(item.get("starts_at"))
            expires = parse_time(item.get("expires_at"))
            revoked = item.get("revoked_at")
            revoked = None if revoked is None else parse_time(revoked)
        except (TypeError, ValueError) as error:
            raise SnapshotError("Token 时间不合法") from error
        if expires <= starts:
            raise SnapshotError("Token 结束时间早于开始时间")
        limits = item.get("limits") or {}
        if not isinstance(limits, dict):
            raise SnapshotError("Token 限额格式不对")
        clean = {}
        for key in LIMIT_KEYS:
            value = limits.get(key)
            if value is None:
                continue
            if isinstance(value, bool) or not isinstance(value, int) or value < 1:
                raise SnapshotError("Token 限额数值不合法")
            clean[key] = value
        entries[digest] = {"token_id": token_id, "user_id": user_id, "starts_at": starts,
                           "expires_at": expires, "revoked_at": revoked, "limits": clean}
    return revision, entries


# ------------------------------------------------------------------ 用量、限流与额度

def _local_window(now):
    """管理服务还没告诉我们日、月边界时，先按网关本机时区估一个（下次上报成功后以管理服务为准）。"""
    local = datetime.datetime.fromtimestamp(now / 1000000.0)
    start = lambda y, m, d: int(time.mktime((y, m, d, 0, 0, 0, 0, 0, -1)) * 1000000)
    following = datetime.date(local.year, local.month, local.day) + datetime.timedelta(days=1)
    year, month = (local.year + 1, 1) if local.month == 12 else (local.year, local.month + 1)
    return {"day_start": start(local.year, local.month, local.day),
            "day_end": start(following.year, following.month, following.day),
            "month_start": start(local.year, local.month, 1), "month_end": start(year, month, 1)}


class UsageMeter:
    """每个 Token 的并发数、最近 60 秒请求数，以及还没上报给管理服务的用量。全部在内存里。"""

    def __init__(self, monotonic=time.monotonic, wall=time.time):
        self._monotonic = monotonic
        self._wall = wall
        self._lock = threading.Lock()
        self._recent = {}        # token_id -> deque(单调时钟秒)
        self._active = {}        # token_id -> 正在进行的请求数
        self._pending = {}       # token_id -> {bucket_us: [requests, asr_ms, mt, clone]}
        self._last_used = {}     # token_id -> 最近一次成功使用（微秒）
        self._inflight = None    # 正在上报、还没确认的一批：(batch_id, items, 原始数据)
        self._base = {}          # token_id -> (day_asr_ms, month_asr_ms)，来自管理服务
        self._window = None      # 管理服务给的日、月边界

    def _window_now(self, now):
        window = self._window
        if window is None or now >= window["day_end"] or now < window["day_start"]:
            return _local_window(now), False
        return window, True

    def _used(self, token_id, now):
        """(今日已用毫秒, 本月已用毫秒, 窗口)：管理服务记录的 + 本网关未确认的。"""
        window, from_service = self._window_now(now)
        base_day, base_month = self._base.get(token_id, (0, 0)) if from_service else (0, 0)
        if not from_service and self._window is not None and now < self._window["month_end"]:
            base_month = self._base.get(token_id, (0, 0))[1]   # 只跨了天、没跨月：月用量还有效
        day = month = 0
        sources = [self._pending.get(token_id, {})]
        if self._inflight is not None:
            sources.append(self._inflight[2].get(token_id, {}))
        for buckets in sources:
            for bucket, values in buckets.items():
                if window["month_start"] <= bucket < window["month_end"]:
                    month += values[1]
                    if window["day_start"] <= bucket < window["day_end"]:
                        day += values[1]
        return base_day + day, base_month + month, window

    def admit(self, token_id, limits):
        """放行返回 None；超限返回拒绝结果（429）。放行后必须调用 release。"""
        now_mono = self._monotonic()
        now = now_us(self._wall)
        with self._lock:
            active = self._active.get(token_id, 0)
            limit = limits.get("max_concurrent")
            if limit and active >= limit:
                return AuthResult.deny("CONCURRENCY_LIMITED", 429,
                                       {"limit": limit, "retry_after_seconds": 1})
            recent = self._recent.setdefault(token_id, collections.deque())
            while recent and now_mono - recent[0] >= 60:
                recent.popleft()
            limit = limits.get("rate_per_minute")
            if limit and len(recent) >= limit:
                wait = max(1, int(math.ceil(60 - (now_mono - recent[0]))))
                return AuthResult.deny("RATE_LIMITED", 429, {"limit": limit, "retry_after_seconds": wait})
            daily, monthly = limits.get("daily_audio_minutes"), limits.get("monthly_audio_minutes")
            if daily or monthly:
                day_ms, month_ms, window = self._used(token_id, now)
                for quota, limit, used, resets in (("daily", daily, day_ms, window["day_end"]),
                                                   ("monthly", monthly, month_ms, window["month_end"])):
                    if limit and used >= limit * 60000:
                        message = "今日识别时长已用完" if quota == "daily" else "本月识别时长已用完"
                        return AuthResult.deny("QUOTA_EXCEEDED", 429, {
                            "quota": quota, "limit_minutes": limit,
                            "used_minutes": round(used / 60000.0, 1), "resets_at": format_time(resets),
                            "retry_after_seconds": max(1, int((resets - now) / 1000000))}, message=message)
            recent.append(now_mono)
            self._active[token_id] = active + 1
        return None

    def release(self, token_id, success, asr_ms=0, translation=False, clone=False):
        now = now_us(self._wall)
        with self._lock:
            active = self._active.get(token_id, 0) - 1
            if active > 0:
                self._active[token_id] = active
            else:
                self._active.pop(token_id, None)
            if not success:
                return
            bucket = now - now % USAGE_BUCKET_US
            values = self._pending.setdefault(token_id, {}).setdefault(bucket, [0, 0, 0, 0])
            values[0] += 1
            values[1] += max(0, int(asr_ms))
            values[2] += 1 if translation else 0
            values[3] += 1 if clone else 0
            self._last_used[token_id] = max(now, self._last_used.get(token_id, 0))

    def status(self, token_id, limits):
        """给 /v1/auth/check 用：限额和已用量（不占用请求次数）。"""
        out = {"limits": dict(limits)}
        if limits.get("daily_audio_minutes") or limits.get("monthly_audio_minutes"):
            with self._lock:
                day_ms, month_ms, window = self._used(token_id, now_us(self._wall))
            out["usage"] = {"today_audio_minutes": round(day_ms / 60000.0, 1),
                            "month_audio_minutes": round(month_ms / 60000.0, 1),
                            "day_resets_at": format_time(window["day_end"]),
                            "month_resets_at": format_time(window["month_end"])}
        return out

    def take_batch(self):
        """取一批待上报的用量。上一批没确认就原样重发（同一个 batch_id，管理服务只记一次）。"""
        with self._lock:
            if self._inflight is not None:
                return self._inflight[0], self._inflight[1]
            now = now_us(self._wall)
            taken, items = {}, []
            for token_id in list(self._pending):
                buckets = self._pending[token_id]
                for bucket in sorted(buckets):
                    if bucket < now - USAGE_KEEP_US:
                        del buckets[bucket]          # 太旧了，管理服务也不收
                        continue
                    if len(items) >= MAX_USAGE_BATCH:
                        break
                    values = buckets.pop(bucket)
                    taken.setdefault(token_id, {})[bucket] = values
                    items.append({"token_id": token_id, "bucket_start": format_time(bucket),
                                  "requests": values[0], "asr_ms": values[1], "mt_requests": values[2],
                                  "clone_requests": values[3]})
                if not buckets:
                    del self._pending[token_id]
                if len(items) >= MAX_USAGE_BATCH:
                    break
            for item in items:
                last = self._last_used.get(item["token_id"])
                if last is not None:
                    item["last_used_at"] = format_time(last)
            batch_id = "b_" + secrets.token_hex(12)
            self._inflight = (batch_id, items, taken)
            return batch_id, items

    def confirm(self, batch_id, response):
        """管理服务已收下这一批：换上它算好的已用量。"""
        window = {key: parse_time(response["window"][key])
                  for key in ("day_start", "day_end", "month_start", "month_end")}
        base = {}
        for total in response.get("totals") or []:
            day, month = total.get("day_asr_ms"), total.get("month_asr_ms")
            if (isinstance(total.get("token_id"), str) and isinstance(day, int) and isinstance(month, int)
                    and not isinstance(day, bool) and not isinstance(month, bool)):
                base[total["token_id"]] = (max(0, day), max(0, month))
        with self._lock:
            if self._inflight is None or self._inflight[0] != batch_id:
                return
            self._inflight = None
            self._window = window
            self._base = base

    def has_pending(self):
        with self._lock:
            return bool(self._pending) or self._inflight is not None


# ------------------------------------------------------------------ 网关端校验器

def _loopback(host):
    if host in ("localhost",):
        return True
    try:
        return ipaddress.ip_address(host).is_loopback
    except ValueError:
        return False


class _NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    """禁止管理 API 跟随 3xx 重定向，防止网关 Bearer 凭据被转发到第三方或降级目标。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, "redirect refused", headers, fp)


class ManagedAuthenticator:
    mode = "managed"

    def __init__(self, api_url, gateway_id, credential, *, ca_file=None, timeout=10.0,
                 refresh_interval=REFRESH_INTERVAL, max_staleness=MAX_STALENESS,
                 retry_interval=RETRY_INTERVAL, monotonic=time.monotonic, wall=time.time,
                 opener=None, logger=None):
        target = urlsplit(api_url.strip())
        if target.scheme not in ("https", "http") or not target.hostname:
            raise AuthConfigError("HEAR_AUTH_API_URL 需要是 https:// 地址")
        if target.scheme == "http" and not _loopback(target.hostname):
            raise AuthConfigError("HEAR_AUTH_API_URL 只有本机地址可以用 http，其他地址必须用 https")
        if not ID_RE.match(gateway_id or ""):
            raise AuthConfigError("HEAR_GATEWAY_ID 不合法（字母、数字、- _ . :，最长 128）")
        if not credential:
            raise AuthConfigError("网关凭据为空")
        base = api_url.strip().rstrip("/")
        self.snapshot_url = "%s/internal/v1/gateways/%s/token-snapshot" % (base, quote(gateway_id, safe=""))
        self.usage_url = "%s/internal/v1/gateways/%s/usage" % (base, quote(gateway_id, safe=""))
        self.gateway_id = gateway_id
        self._credential = credential
        self.timeout = timeout
        self.refresh_interval = refresh_interval
        self.max_staleness = max_staleness
        self.retry_interval = retry_interval
        self._monotonic = monotonic
        self._wall = wall
        self._log = logger or (lambda message: None)
        if opener is None:
            context = ssl.create_default_context(cafile=ca_file) if ca_file else ssl.create_default_context()
            # 内部 API 直连，不走系统代理、禁止跟随 3xx 重定向，也不允许代理缓存顶替在线检查
            opener = urllib.request.build_opener(urllib.request.ProxyHandler({}),
                                                 _NoRedirectHandler(),
                                                 urllib.request.HTTPSHandler(context=context))
        self._opener = opener
        self._lock = threading.Lock()
        self._entries = None
        self._revision = None
        self._etag = None
        self._last_success = None
        self._last_error = "尚未同步"
        self._failing = False
        self.sync_attempts = 0
        self.meter = UsageMeter(monotonic=monotonic, wall=wall)
        self._usage_supported = True
        self._usage_failing = False
        self.usage_reports = 0
        self._stop = threading.Event()
        self._thread = None

    # -- 同步 --

    def _fetch(self):
        request = urllib.request.Request(self.snapshot_url, method="GET")
        request.add_header("Authorization", "Bearer " + self._credential)
        request.add_header("Accept", "application/json")
        request.add_header("Cache-Control", "no-cache")
        with self._lock:
            etag = self._etag if self._entries is not None else None
        if etag:
            request.add_header("If-None-Match", etag)
        try:
            with self._opener.open(request, timeout=self.timeout) as response:
                body = response.read(MAX_SNAPSHOT_BYTES + 1)
                return response.status, response.headers, body
        except urllib.error.HTTPError as error:
            try:
                error.read(4096)
            finally:
                error.close()
            return error.code, error.headers, b""

    def sync_once(self):
        """拉一次清单。成功返回 True。失败时保留旧清单，只在缓存窗口内继续使用。"""
        self.sync_attempts += 1
        try:
            status, headers, body = self._fetch()
            if status == 304:
                with self._lock:
                    if self._entries is None:
                        raise SnapshotError("没有本地清单时收到 304")
                    self._last_success = self._monotonic()
                self._mark_ok(None)
                return True
            if status != 200:
                raise SnapshotError("管理服务返回 HTTP %d" % status)
            if len(body) > MAX_SNAPSHOT_BYTES:
                raise SnapshotError("清单过大")
            length = headers.get("Content-Length")
            if length is not None and length.isdigit() and int(length) != len(body):
                raise SnapshotError("清单未传输完整")
            revision, entries = parse_snapshot(body, self.gateway_id)
            with self._lock:
                if self._revision is not None and revision < self._revision:
                    raise SnapshotError("修订号回退（%d < %d）" % (revision, self._revision))
                changed = revision != self._revision
                self._entries = entries
                self._revision = revision
                self._etag = headers.get("ETag")
                self._last_success = self._monotonic()
            self._mark_ok("鉴权清单已更新：修订号 %d，%d 条记录" % (revision, len(entries)) if changed else None)
            return True
        except (SnapshotError, urllib.error.URLError, OSError, ValueError,
                ssl.SSLError, http.client.HTTPException) as error:
            reason = getattr(error, "reason", None) or error
            self._mark_failure("%s" % reason)
            return False

    def _mark_ok(self, message):
        recovered = self._failing
        self._failing = False
        self._last_error = None
        if recovered:
            self._log("鉴权清单同步已恢复")
        if message:
            self._log(message)

    def _mark_failure(self, reason):
        self._last_error = reason
        if not self._failing:
            self._log("鉴权清单同步失败：%s（超过 %d 秒没同步成功会拒绝推理）" % (reason, int(self.max_staleness)))
        self._failing = True

    def _needs_report(self):
        if self.meter.has_pending():
            return True
        with self._lock:
            entries = self._entries or {}
            # 有额度限制的 Token：哪怕本网关没用，也要定期取回别的网关用掉的量
            return any(entry["limits"].get("daily_audio_minutes") or entry["limits"].get("monthly_audio_minutes")
                       for entry in entries.values())

    def report_usage(self):
        """把用量批量交给管理服务，并取回有额度 Token 的已用量。不影响口令校验。"""
        if not self._usage_supported or not self._needs_report():
            return True
        batch_id, items = self.meter.take_batch()
        body = json.dumps({"batch_id": batch_id, "items": items}).encode("utf-8")
        request = urllib.request.Request(self.usage_url, data=body, method="POST")
        request.add_header("Authorization", "Bearer " + self._credential)
        request.add_header("Content-Type", "application/json")
        request.add_header("Accept", "application/json")
        try:
            try:
                with self._opener.open(request, timeout=self.timeout) as response:
                    raw = response.read(MAX_SNAPSHOT_BYTES + 1)
            except urllib.error.HTTPError as error:
                try:
                    error.read(4096)
                finally:
                    error.close()
                if error.code in (404, 405):
                    # 旧版管理服务没有用量接口：只在本网关内存里限流和计额度
                    self._usage_supported = False
                    self._log("管理服务不支持用量上报（HTTP %d），识别时长额度只按本网关计算" % error.code)
                    return False
                raise SnapshotError("用量上报返回 HTTP %d" % error.code)
            self.meter.confirm(batch_id, json.loads(raw.decode("utf-8")))
            self.usage_reports += 1
            if self._usage_failing:
                self._log("用量上报已恢复")
            self._usage_failing = False
            return True
        except (SnapshotError, urllib.error.URLError, OSError, ValueError, KeyError, TypeError,
                ssl.SSLError, http.client.HTTPException) as error:
            if not self._usage_failing:
                self._log("用量上报失败：%s（用量先留在本网关，稍后重发）" % (getattr(error, "reason", None) or error))
            self._usage_failing = True
            return False

    def admit(self, result):
        """口令已通过：再检查这个 Token 的限流和额度。放行返回 None。"""
        if result.subject is None:
            return None
        return self.meter.admit(result.subject, result.limits)

    def release(self, result, success, **usage):
        if result.subject is not None:
            self.meter.release(result.subject, success, **usage)

    def usage_status(self, result):
        if result.subject is None:
            return {}
        return self.meter.status(result.subject, result.limits)

    def start(self):
        if self._thread is not None:
            return
        self._thread = threading.Thread(target=self._run, name="hear-auth-sync", daemon=True)
        self._thread.start()

    def stop(self):
        self._stop.set()

    def _run(self):
        while not self._stop.is_set():
            try:
                ok = self.sync_once()
            except Exception as error:
                # 单次异常不能让鉴权清单同步线程永久退出。
                self._mark_failure("%s: %s" % (type(error).__name__, error))
                ok = False
            try:
                self.report_usage()
            except Exception as error:  # 用量上报出错不能影响清单同步
                self._log("用量上报异常：%s: %s" % (type(error).__name__, error))
            self._stop.wait(self.refresh_interval if ok else min(self.retry_interval, self.refresh_interval))

    # -- 查询 --

    def ready(self):
        with self._lock:
            if self._entries is None or self._last_success is None:
                return False
            return self._monotonic() - self._last_success <= self.max_staleness

    def health(self):
        out = {"auth_mode": self.mode, "auth_ready": self.ready()}
        if not out["auth_ready"]:
            out["auth_detail"] = "口令清单尚未加载或同步超时"
        return out

    def verify(self, token):
        """只在内存里完成：计算一次摘要，查表，比较时间和撤销状态。"""
        if not token:
            return AuthResult.deny("TOKEN_REQUIRED")
        with self._lock:
            fresh = (self._entries is not None and self._last_success is not None
                     and self._monotonic() - self._last_success <= self.max_staleness)
            entries = self._entries
        if not fresh:
            return AuthResult.deny("AUTH_SERVICE_UNAVAILABLE", 503)
        entry = entries.get(token_digest(token))
        if entry is None:
            return AuthResult.deny("TOKEN_INVALID")
        now = now_us(self._wall)
        info = describe(entry, now)
        info["server_time"] = format_time(now)
        status = info["status"]
        if status == "active":
            info["active"] = True
            result = AuthResult.allow(info)
            result.subject = entry["token_id"]
            result.limits = entry.get("limits") or {}
            return result
        info["active"] = False
        code = {"scheduled": "TOKEN_NOT_STARTED", "expired": "TOKEN_EXPIRED",
                "revoked": "TOKEN_REVOKED"}[status]
        return AuthResult.deny(code, 401, info)


def read_credential(path):
    try:
        with open(path, "r", encoding="utf-8-sig") as file:
            credential = file.read().strip()
    except OSError as error:
        raise AuthConfigError("读不了网关凭据文件 %s：%s" % (path, error.strerror or error)) from error
    if not credential or len(credential) > 4096 or any(ch.isspace() for ch in credential):
        raise AuthConfigError("网关凭据文件 %s 内容为空或格式不对" % path)
    return credential


def auth_mode_from_env(env=None):
    env = os.environ if env is None else env
    mode = (env.get("HEAR_AUTH_MODE") or "").strip().lower()
    if mode in ("", "legacy"):
        return "legacy"
    if mode in ("managed", "off"):
        return mode
    raise AuthConfigError("HEAR_AUTH_MODE 只能是 managed、legacy 或 off（现在是 %r）" % mode)


def managed_from_env(env=None, logger=None, **kwargs):
    """读取管理模式配置。缺项时抛 AuthConfigError，并说明缺了什么。"""
    env = os.environ if env is None else env
    missing = [name for name in ("HEAR_AUTH_API_URL", "HEAR_GATEWAY_ID", "HEAR_GATEWAY_CREDENTIAL_FILE")
               if not (env.get(name) or "").strip()]
    if missing:
        raise AuthConfigError("管理模式配置不完整，缺少：%s" % "、".join(missing))
    ca_file = (env.get("HEAR_AUTH_CA_FILE") or "").strip() or None
    if ca_file and not os.path.isfile(ca_file):
        raise AuthConfigError("HEAR_AUTH_CA_FILE 指向的文件不存在：%s" % ca_file)
    credential = read_credential(env["HEAR_GATEWAY_CREDENTIAL_FILE"].strip())
    # 默认 30 秒刷新、60 秒过期；只给测试和排障用的覆盖项，过期窗口不能短于刷新间隔
    try:
        refresh = float(env.get("HEAR_AUTH_REFRESH_SECONDS") or REFRESH_INTERVAL)
        staleness = float(env.get("HEAR_AUTH_MAX_STALENESS_SECONDS") or MAX_STALENESS)
    except ValueError:
        raise AuthConfigError("HEAR_AUTH_REFRESH_SECONDS / HEAR_AUTH_MAX_STALENESS_SECONDS 需要是数字")
    if not (0.2 <= refresh <= 300 and refresh <= staleness <= 600):
        raise AuthConfigError("刷新间隔需在 0.2~300 秒之间，过期窗口不能短于刷新间隔")
    kwargs.setdefault("refresh_interval", refresh)
    kwargs.setdefault("max_staleness", staleness)
    kwargs.setdefault("retry_interval", min(RETRY_INTERVAL, refresh))
    return ManagedAuthenticator(env["HEAR_AUTH_API_URL"], env["HEAR_GATEWAY_ID"].strip(), credential,
                                ca_file=ca_file, logger=logger, **kwargs)
