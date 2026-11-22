# -*- coding: utf-8 -*-
"""Token 管理服务 + 网关托管鉴权 + --check-token 的端到端自测（只用标准库和 cryptography）。

    python3 server/test_token_auth.py
"""
import argparse
import http.client
import http.cookiejar
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import hear_auth  # noqa: E402
import hear_token_service  # noqa: E402
from hear_http import RequestPolicy  # noqa: E402
from hear_token_store import Store, StoreError  # noqa: E402

PASSED, FAILED = [], []
REFRESH = 1.0
STALE = 3.0


def check(name, ok, detail=""):
    (PASSED if ok else FAILED).append(name)
    print("  ok %s" % name if ok else "  FAIL %s %s" % (name, detail))


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def insecure():
    context = ssl.create_default_context()
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    return context


class Admin:
    """模拟浏览器：同源 Cookie 会话 + X-CSRF-Token。"""

    def __init__(self, base, context):
        self.base, self.csrf = base, None
        self.jar = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(self.jar),
                                                  urllib.request.HTTPSHandler(context=context),
                                                  urllib.request.ProxyHandler({}))

    def call(self, method, path, body=None, csrf=True, headers=None):
        request = urllib.request.Request(self.base + "/admin/api/v1" + path, method=method,
                                         data=None if body is None else json.dumps(body).encode())
        if body is not None:
            request.add_header("Content-Type", "application/json")
        if csrf and self.csrf:
            request.add_header("X-CSRF-Token", self.csrf)
        for key, value in (headers or {}).items():
            request.add_header(key, value)
        try:
            with self.opener.open(request, timeout=10) as response:
                raw = response.read()
                return response.status, (json.loads(raw) if raw else None), response.headers
        except urllib.error.HTTPError as error:
            raw = error.read()
            return error.code, (json.loads(raw) if raw else None), error.headers

    def login(self, username, password):
        status, body, _ = self.call("POST", "/session", {"username": username, "password": password}, csrf=False)
        if status == 201:
            self.csrf = body["csrf_token"]
        return status, body


def https_get(port, path, token=None, context=None, host="127.0.0.1"):
    connection = http.client.HTTPSConnection(host, port, timeout=10, context=context or insecure())
    headers = {"X-Hear-Token": token} if token is not None else {}
    try:
        connection.request("GET", path, headers=headers)
        response = connection.getresponse()
        raw = response.read()
        return response.status, json.loads(raw) if raw else None, response.headers
    finally:
        connection.close()


def https_post(port, path, body=b"", token=None):
    connection = http.client.HTTPSConnection("127.0.0.1", port, timeout=10, context=insecure())
    headers = {"Content-Type": "audio/wav"}
    if token is not None:
        headers["X-Hear-Token"] = token
    try:
        connection.request("POST", path, body=body, headers=headers)
        response = connection.getresponse()
        raw = response.read()
        return response.status, json.loads(raw) if raw else None, response.headers
    finally:
        connection.close()


class StubASR(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self._reply(b'{"status":"ok"}')

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        self._reply(json.dumps({"text": "stub", "language": "zh"}).encode())

    def _reply(self, body):
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def make_wav():
    import io
    import struct
    import wave
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as file:
        file.setnchannels(1)
        file.setsampwidth(2)
        file.setframerate(16000)
        file.writeframes(struct.pack("<16000h", *([800] * 16000)))
    return buffer.getvalue()


# ====================================================================== 单元：网关端校验器

def unit_authenticator():
    print("== gateway verifier (fake clocks) ==")
    clock = {"mono": 1000.0, "wall": 1_800_000_000.0}
    responses = []

    class FakeResponse:
        def __init__(self, status, body, headers):
            self.status, self._body, self.headers = status, body, headers

        def read(self, _=None):
            return self._body

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

    class FakeOpener:
        def open(self, request, timeout=None):
            status, body, headers = responses.pop(0)
            if isinstance(status, Exception):
                raise status
            if status >= 400 or status == 304:
                if status == 304:
                    return FakeResponse(304, b"", headers)
                raise urllib.error.HTTPError(request.full_url, status, "x", headers, None)
            return FakeResponse(status, body, headers)

    def snapshot(revision, tokens, gateway="gw-a"):
        return json.dumps({"gateway_id": gateway, "revision": revision, "generated_at": "2027-01-15T08:00:00Z",
                           "digest_algorithm": "sha256", "tokens": tokens}).encode()

    now = hear_auth.format_time(int(clock["wall"] * 1e6))
    good = {"token_id": "tok_1", "user_id": "usr_1", "sha256": hear_auth.token_digest("hear_ut_good"),
            "starts_at": "2020-01-01T00:00:00Z", "expires_at": "2099-01-01T00:00:00+08:00", "revoked_at": None}
    future = dict(good, token_id="tok_2", sha256=hear_auth.token_digest("hear_ut_future"),
                  starts_at="2098-01-01T00:00:00Z")
    edge = dict(good, token_id="tok_3", sha256=hear_auth.token_digest("hear_ut_edge"), expires_at=now)
    starts_now = dict(good, token_id="tok_4", sha256=hear_auth.token_digest("hear_ut_start"), starts_at=now)
    revoked = dict(good, token_id="tok_5", sha256=hear_auth.token_digest("hear_ut_rev"),
                   revoked_at="2021-01-01T00:00:00Z")
    auth = hear_auth.ManagedAuthenticator("https://tokens.example", "gw-a", "hear_gw_x", opener=FakeOpener(),
                                          monotonic=lambda: clock["mono"], wall=lambda: clock["wall"])
    check("cold start without a snapshot refuses with 503",
          auth.verify("hear_ut_good").code == "AUTH_SERVICE_UNAVAILABLE" and not auth.ready())
    responses.append((200, snapshot(5, [good, future, edge, starts_now, revoked]), {"ETag": '"e1"'}))
    check("a valid snapshot loads", auth.sync_once() and auth.ready())
    check("an active token passes", auth.verify("hear_ut_good").ok)
    check("a missing token is TOKEN_REQUIRED", auth.verify("").code == "TOKEN_REQUIRED")
    check("an unknown token is TOKEN_INVALID", auth.verify("hear_ut_nope").code == "TOKEN_INVALID")
    check("a scheduled token is TOKEN_NOT_STARTED", auth.verify("hear_ut_future").code == "TOKEN_NOT_STARTED")
    check("the end time is exclusive (expires_at == now is expired)", auth.verify("hear_ut_edge").code == "TOKEN_EXPIRED")
    check("the start time is inclusive (starts_at == now is active)", auth.verify("hear_ut_start").ok)
    result = auth.verify("hear_ut_rev")
    check("a revoked token is TOKEN_REVOKED with invalidated_at",
          result.code == "TOKEN_REVOKED" and result.details["invalidated_at"] == "2021-01-01T00:00:00Z")
    check("offsets are normalised to UTC", auth.verify("hear_ut_good").details["expires_at"] == "2098-12-31T16:00:00Z")
    responses.append((304, b"", {}))
    clock["mono"] += 50
    check("304 refreshes the sync time", auth.sync_once() and auth.ready())
    clock["mono"] += 59
    check("still ready 59 s after the last success", auth.ready())
    responses.append((urllib.error.URLError(ConnectionRefusedError()), None, None))
    check("a network failure counts as a failed sync", not auth.sync_once())
    clock["mono"] += 2
    check("over 60 s without success refuses with 503",
          not auth.ready() and auth.verify("hear_ut_good").http_status == 503)
    for name, body in (("revision rollback", snapshot(4, [good])), ("another gateway's snapshot", snapshot(9, [good], "gw-b")),
                       ("malformed digest", snapshot(9, [dict(good, sha256="xyz")])), ("truncated JSON", b'{"gateway_id":')):
        responses.append((200, body, {}))
        check("%s is rejected" % name, not auth.sync_once() and not auth.ready())
    responses.append((200, snapshot(6, []), {}))
    check("an empty snapshot is valid and replaces the old one",
          auth.sync_once() and auth.ready() and auth.verify("hear_ut_good").code == "TOKEN_INVALID")
    responses.append((401, b"", {}))
    check("a rejected gateway credential is a failed sync", not auth.sync_once())

    policy = RequestPolicy(1024, 1, authenticator=auth)

    class Plain:
        pass
    check("managed mode refuses plain HTTP even with a token",
          policy.authorize(Plain(), "192.0.2.10", "hear_ut_good").code == "HTTPS_REQUIRED")
    tunnel = RequestPolicy(1024, 1, allow_loopback_http=True, authenticator=auth)
    check("the opt-in loopback HTTP origin still needs a valid managed token",
          tunnel.authorize(Plain(), "127.0.0.1", "hear_ut_nope").code == "TOKEN_INVALID"
          and tunnel.authorize(Plain(), "192.0.2.10", "hear_ut_nope").code == "HTTPS_REQUIRED")
    legacy = RequestPolicy(1024, 1, access_token="shared")
    check("legacy shared-token mode still refuses plain HTTP", not legacy.permits(Plain(), "127.0.0.1", "shared"))
    check("no-token mode still admits plain HTTP", RequestPolicy(1024, 1).permits(Plain(), "127.0.0.1", ""))
    try:
        hear_auth.managed_from_env({"HEAR_AUTH_MODE": "managed", "HEAR_GATEWAY_ID": "gw"})
        check("incomplete managed configuration is a clear error", False)
    except hear_auth.AuthConfigError as error:
        check("incomplete managed configuration is a clear error",
              "HEAR_AUTH_API_URL" in str(error) and "HEAR_GATEWAY_CREDENTIAL_FILE" in str(error))
    try:
        hear_auth.ManagedAuthenticator("http://10.0.0.5:8443", "gw", "hear_gw_x")
        check("a non-loopback http management URL is refused", False)
    except hear_auth.AuthConfigError:
        check("a non-loopback http management URL is refused", True)


# ====================================================================== 单元：数据层

def unit_store(tmp):
    print("\n== store rules ==")
    clock = {"t": 1_900_000_000.0}
    store = Store(os.path.join(tmp, "unit.db"), clock=lambda: clock["t"])
    store.migrate()
    check("migrations are idempotent", store.migrate() == [] and store.schema_version() == 1)
    actor = {"type": "cli", "id": "test", "username": "test"}
    store.create_gateway("gw-unit")
    user = store.create_user({"username": "Alice", "display_name": "爱丽丝"}, actor)
    try:
        store.create_user({"username": "alice"}, actor)
        check("usernames are unique regardless of case", False)
    except StoreError as error:
        check("usernames are unique regardless of case", error.http_status == 409)
    base = hear_auth.format_time(int(clock["t"] * 1e6))
    a = store.issue_token(user["user_id"], {"label": "a", "gateway_id": "gw-unit", "starts_at": "2030-03-18T01:46:40+08:00",
                                            "expires_at": "2030-04-01T00:00:00Z"}, actor)
    b = store.issue_token(user["user_id"], {"label": "b", "gateway_id": "gw-unit", "starts_at": "2030-03-17T17:46:40Z",
                                            "expires_at": "2030-03-31T19:00:00-05:00"}, actor)
    check("the same instant written in different time zones is stored identically",
          a["starts_at"] == b["starts_at"] == base == "2030-03-17T17:46:40Z" and a["expires_at"] == b["expires_at"])
    check("the token starts active exactly at starts_at", a["status"] == "active")
    check("the raw token has the hear_ut_ prefix and >= 256 bits", a["token"].startswith("hear_ut_") and len(a["token"]) >= 8 + 43)
    check("only the suffix is stored in clear", a["token_suffix"] == a["token"][-6:]
          and store.conn().execute("SELECT COUNT(*) FROM tokens WHERE sha256 = ?", (hear_auth.token_digest(a["token"]),)).fetchone()[0] == 1)
    dump = "\n".join(str(tuple(row)) for table in ("tokens", "audit_events", "users", "gateways")
                     for row in store.conn().execute("SELECT * FROM %s" % table))
    check("no raw token in the database or audit log", a["token"] not in dump and b["token"] not in dump)
    for body, field in (({"label": "x", "gateway_id": "gw-unit", "expires_at": "2030-03-17T09:46:40Z"}, "expires_at"),
                        ({"label": "x", "gateway_id": "gw-unit", "expires_at": "2030-04-01T00:00:00"}, "expires_at"),
                        ({"label": "x", "gateway_id": "gw-unit"}, "expires_at"),
                        ({"label": "", "gateway_id": "gw-unit", "expires_at": "2031-01-01T00:00:00Z"}, "label"),
                        ({"label": "x", "gateway_id": "nope", "expires_at": "2031-01-01T00:00:00Z"}, "gateway_id")):
        try:
            store.issue_token(user["user_id"], body, actor)
            check("invalid issue (%s) is 422" % field, False)
        except StoreError as error:
            check("invalid issue (%s) is 422" % field, error.http_status == 422 and error.field == field, error.message)
    revision = store.list_gateways()["items"][0]["revision"]
    store.update_token(a["token_id"], {"label": "renamed"}, actor)
    check("a label change does not bump the gateway revision", store.list_gateways()["items"][0]["revision"] == revision)
    store.update_token(a["token_id"], {"expires_at": "2030-05-01T00:00:00Z"}, actor)
    check("a validity change bumps the gateway revision", store.list_gateways()["items"][0]["revision"] > revision)
    restored = store.list_gateways()["items"][0]["revision"]
    store.conn().execute("UPDATE gateways SET revision = 3")  # 模拟从旧备份恢复
    clock["t"] += 60
    store.bump_all()
    check("a restart after restoring an old backup moves the revision past every earlier value",
          store.list_gateways()["items"][0]["revision"] > restored)
    clock["t"] += 40 * 86400  # 越过 a 和 b 的原定结束
    check("natural expiry is computed without a scheduled job",
          store.get_token(b["token_id"])["status"] == "expired"
          and store.get_token(b["token_id"])["invalidated_at"] == "2030-04-01T00:00:00Z")
    try:
        store.update_token(b["token_id"], {"label": "late"}, actor)
        check("editing an expired token is 409", False)
    except StoreError as error:
        check("editing an expired token is 409", error.http_status == 409)
    store.revoke_token(a["token_id"], None, actor)
    first = store.get_token(a["token_id"])
    clock["t"] += 10
    store.revoke_token(a["token_id"], "again", actor)
    check("repeated revocation keeps the first result", store.get_token(a["token_id"]) == first and first["status"] == "revoked")
    page = store.list_user_tokens(user["user_id"], limit=1)
    second = store.list_user_tokens(user["user_id"], limit=1, cursor=page["next_cursor"])
    check("cursor pagination returns each item once",
          len(page["items"]) == 1 and len(second["items"]) == 1 and page["items"][0]["token_id"] != second["items"][0]["token_id"]
          and second["next_cursor"] is None)
    clock["t"] += 100 * 86400
    body, _ = store.snapshot("gw-unit")
    check("tokens invalidated more than 90 days ago leave the snapshot", body["tokens"] == [])


# ====================================================================== 端到端

def start_gateway(tmp, port, env_extra):
    env = dict(os.environ)
    for key in ("HEAR_REQUIRE_TOKEN", "HEAR_AUTH_MODE", "HEAR_AUTH_API_URL", "HEAR_GATEWAY_ID",
                "HEAR_GATEWAY_CREDENTIAL_FILE", "HEAR_AUTH_CA_FILE"):
        env.pop(key, None)
    env.update({
        "HEAR_PORT": str(port), "HEAR_HOST": "127.0.0.1", "PYTHONUTF8": "1",
        "HEAR_TLS_CERT": os.path.join(tmp, "cert.pem"), "HEAR_TLS_KEY": os.path.join(tmp, "key.pem"),
        "HEAR_ROOT_CERT": os.path.join(tmp, "root.pem"), "HEAR_ROOT_KEY": os.path.join(tmp, "root.key"),
        "HEAR_SENSEVOICE_DIR": os.path.join(tmp, "sensevoice"),
        "HEAR_TOKEN_FILE": os.path.join(tmp, "access-token.txt"),
        "HEAR_MT_URL": "http://127.0.0.1:9", "HEAR_CLONE_URL": "http://127.0.0.1:9",
    })
    env.update(env_extra)
    log_file = open(os.path.join(tmp, "gateway-%d.log" % port), "wb")
    proc = subprocess.Popen([sys.executable, os.path.join(HERE, "hear_cloud.py")], env=env,
                            stdout=log_file, stderr=subprocess.STDOUT)
    for _ in range(80):
        try:
            status, _, _ = https_get(port, "/health")
            if status == 200:
                return proc
        except OSError:
            pass
        if proc.poll() is not None:
            break
        time.sleep(0.25)
    return proc


def stop(proc):
    try:
        proc.terminate()
        proc.wait(timeout=5)
    except Exception:
        proc.kill()


def wait_for(predicate, seconds):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if predicate():
                return True
        except (OSError, KeyError, TypeError, ValueError):
            pass
        time.sleep(0.2)
    return False


def run_check(port, token, tmp, url=None):
    env = dict(os.environ, HEAR_ROOT_CERT=os.path.join(tmp, "root.pem"), PYTHONUTF8="1")
    result = subprocess.run([sys.executable, os.path.join(HERE, "hear_check_token.py"),
                             url or "https://127.0.0.1:%d" % port], input=(token + "\n").encode(),
                            stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env, timeout=30)
    return result.returncode, result.stdout.decode("utf-8", "replace")


def end_to_end(tmp):
    print("\n== token service + managed gateway ==")
    hear_token_service.log = lambda message: None
    cert, key = os.path.join(tmp, "svc-cert.pem"), os.path.join(tmp, "svc-key.pem")
    hear_token_service.cmd_gen_cert(None, argparse.Namespace(cert=cert, key=key, host=["127.0.0.1", "localhost"]))
    store = Store(os.path.join(tmp, "e2e.db"))
    store.migrate()
    store.create_admin("admin", "correct horse battery", "admin")
    store.create_admin("viewer", "correct horse battery", "viewer")
    _, credential = store.create_gateway("hear-test", "测试网关")
    _, other_credential = store.create_gateway("hear-other")
    credential_file = os.path.join(tmp, "gateway.cred")
    hear_token_service.write_secret_file(credential_file, credential)
    svc_port = free_port()

    def serve():
        server = hear_token_service.TokenServer(("127.0.0.1", svc_port), store,
                                                hear_token_service.make_tls_context(cert, key))
        threading.Thread(target=server.serve_forever, daemon=True).start()
        return server
    service = serve()
    service_ctx = ssl.create_default_context(cafile=cert)
    base = "https://127.0.0.1:%d" % svc_port

    # ---------- 管理后台
    admin = Admin(base, service_ctx)
    status, page, _ = admin.call("GET", "/users")
    check("the admin API requires a session (401)", status == 401 and page["code"] == "UNAUTHENTICATED" and page["request_id"])
    check("a wrong password is refused", admin.login("admin", "wrong password!!")[0] == 401)
    check("the admin can sign in", admin.login("admin", "correct horse battery")[0] == 201)
    cookie = next(iter(admin.jar))
    check("the session cookie is HttpOnly, Secure and SameSite=Strict",
          cookie.secure and cookie.has_nonstandard_attr("HttpOnly") and cookie.get_nonstandard_attr("SameSite") == "Strict")
    status, _, _ = admin.call("POST", "/users", {"username": "nocsrf"}, csrf=False)
    check("a write without the CSRF header is refused (403)", status == 403)
    status, _, _ = admin.call("POST", "/users", {"username": "xsite"}, headers={"Origin": "https://evil.example"})
    check("a cross-origin write is refused (403)", status == 403)
    status, user, headers = admin.call("POST", "/users", {"username": "bob", "display_name": "Bob", "notes": "iPhone"})
    check("create user returns 201 with user_id", status == 201 and user["user_id"].startswith("usr_"))
    check("admin responses are not cacheable", headers.get("Cache-Control") == "no-store")
    check("a duplicate username is 409", admin.call("POST", "/users", {"username": "BOB"})[0] == 409)
    check("an unknown field is 422", admin.call("POST", "/users", {"username": "z", "role": "x"})[0] == 422)
    uid = user["user_id"]
    for name in ("carol", "dave", "erin"):
        admin.call("POST", "/users", {"username": name})
    status, first, _ = admin.call("GET", "/users?limit=2")
    status2, second, _ = admin.call("GET", "/users?limit=2&cursor=" + first["next_cursor"])
    check("user list paginates with limit/cursor", len(first["items"]) == 2 and len(second["items"]) == 2
          and not {u["user_id"] for u in first["items"]} & {u["user_id"] for u in second["items"]})
    check("user search works", [u["username"] for u in admin.call("GET", "/users?search=car")[1]["items"]] == ["carol"])

    def iso(offset):
        return hear_auth.format_time(int((time.time() + offset) * 1e6))
    issued = {}
    for label, starts, expires in (("phone", -60, 3600), ("ipad", -60, 3600), ("later", 3600, 7200), ("short", -60, 6)):
        status, body, _ = admin.call("POST", "/users/%s/tokens" % uid, {"label": label, "gateway_id": "hear-test",
                                                                       "starts_at": iso(starts), "expires_at": iso(expires)})
        issued[label] = body
    check("issuing returns 201 and the raw token once", status == 201 and all(t["token"].startswith("hear_ut_") for t in issued.values()))
    status, listing, _ = admin.call("GET", "/users/%s/tokens" % uid)
    raw_tokens = [t["token"] for t in issued.values()]
    check("token lists never contain raw tokens", status == 200 and len(listing["items"]) == 4
          and not any(raw in json.dumps(listing) for raw in raw_tokens) and "token" not in listing["items"][0])
    status, meta, _ = admin.call("GET", "/tokens/" + issued["later"]["token_id"])
    check("token metadata reports scheduled with all fields", status == 200 and meta["status"] == "scheduled"
          and all(k in meta for k in ("token_id", "user_id", "gateway_id", "label", "token_suffix", "starts_at", "expires_at",
                                       "effective_expires_at", "invalidated_at", "revocation_reason", "created_at", "updated_at")))
    check("tokens filter by status", [t["label"] for t in admin.call("GET", "/users/%s/tokens?status=scheduled" % uid)[1]["items"]] == ["later"])
    check("a bad time zone-less time is 422", admin.call("PATCH", "/tokens/" + issued["phone"]["token_id"],
                                                        {"expires_at": "2099-01-01T00:00:00"})[0] == 422)
    viewer = Admin(base, service_ctx)
    viewer.login("viewer", "correct horse battery")
    check("a viewer can read", viewer.call("GET", "/users")[0] == 200)
    check("a viewer cannot write (403)", viewer.call("POST", "/users", {"username": "v"})[0] == 403)

    # ---------- 网关清单接口
    snapshot_url = base + "/internal/v1/gateways/hear-test/token-snapshot"

    def snap(credential_value, url=snapshot_url, etag=None):
        request = urllib.request.Request(url)
        if credential_value:
            request.add_header("Authorization", "Bearer " + credential_value)
        if etag:
            request.add_header("If-None-Match", etag)
        try:
            with urllib.request.urlopen(request, context=service_ctx, timeout=10) as response:
                return response.status, json.loads(response.read() or b"null"), response.headers
        except urllib.error.HTTPError as error:
            return error.code, None, error.headers
    check("the snapshot requires a gateway credential", snap(None)[0] == 401)
    check("a user token cannot read the snapshot", snap(issued["phone"]["token"])[0] == 401)
    check("another gateway's credential cannot read this snapshot", snap(other_credential)[0] == 403)
    request = urllib.request.Request(base + "/admin/api/v1/users", headers={"Authorization": "Bearer " + credential})
    try:
        urllib.request.urlopen(request, context=service_ctx, timeout=10)
        check("the gateway credential cannot use the admin API", False)
    except urllib.error.HTTPError as error:
        check("the gateway credential cannot use the admin API", error.code == 401)
    status, body, headers = snap(credential)
    check("the snapshot has the documented shape", status == 200 and body["gateway_id"] == "hear-test"
          and body["digest_algorithm"] == "sha256" and len(body["tokens"]) == 4
          and set(body["tokens"][0]) == {"token_id", "user_id", "sha256", "starts_at", "expires_at", "revoked_at"})
    check("the snapshot contains digests, not raw tokens", not any(raw in json.dumps(body) for raw in raw_tokens))
    check("the snapshot is not cacheable and has an ETag", headers.get("Cache-Control") == "no-store" and headers.get("ETag"))
    check("If-None-Match returns 304 when unchanged", snap(credential, etag=headers["ETag"])[0] == 304)

    # ---------- 网关
    gw_tmp = os.path.join(tmp, "gw")
    os.makedirs(gw_tmp)
    stub = ThreadingHTTPServer(("127.0.0.1", 0), StubASR)
    threading.Thread(target=stub.serve_forever, daemon=True).start()
    gw_port = free_port()
    managed_env = {"HEAR_AUTH_MODE": "managed", "HEAR_AUTH_API_URL": base, "HEAR_GATEWAY_ID": "hear-test",
                   "HEAR_GATEWAY_CREDENTIAL_FILE": credential_file, "HEAR_AUTH_CA_FILE": cert,
                   "HEAR_AUTH_REFRESH_SECONDS": str(REFRESH), "HEAR_AUTH_MAX_STALENESS_SECONDS": str(STALE),
                   "HEAR_ASR_URL": "http://127.0.0.1:%d" % stub.server_port,
                   # 旧口令文件即使存在也不作为后备
                   "HEAR_REQUIRE_TOKEN": "1"}
    with open(os.path.join(gw_tmp, "access-token.txt"), "w") as file:
        file.write("legacy-shared-token")
    gateway = start_gateway(gw_tmp, gw_port, managed_env)
    wav = make_wav()
    try:
        check("the gateway reports auth_ready after loading the snapshot",
              wait_for(lambda: https_get(gw_port, "/health")[1].get("auth_ready") is True, 15))
        _, health, _ = https_get(gw_port, "/health")
        check("/health keeps model flags and adds auth_mode", health["auth_mode"] == "managed"
              and all(k in health for k in ("asr_ready", "mt_ready", "clone_ready")))
        status, body, headers = https_get(gw_port, "/v1/auth/check", issued["phone"]["token"])
        check("/v1/auth/check accepts an active token", status == 200 and body["active"] is True
              and body["status"] == "active" and body["server_time"] and headers.get("Cache-Control") == "no-store")
        for label, code in (("later", "TOKEN_NOT_STARTED"),):
            status, body, _ = https_get(gw_port, "/v1/auth/check", issued[label]["token"])
            check("/v1/auth/check reports %s" % code, status == 401 and body["code"] == code
                  and body["error"] == body["message"] and body["starts_at"])
        status, body, _ = https_get(gw_port, "/v1/auth/check", "")
        check("a missing token is 401 TOKEN_REQUIRED", status == 401 and body["code"] == "TOKEN_REQUIRED")
        status, body, _ = https_get(gw_port, "/v1/auth/check", "legacy-shared-token")
        check("the legacy access-token.txt is not a fallback", status == 401 and body["code"] == "TOKEN_INVALID")
        status, body, _ = https_post(gw_port, "/v1/asr", wav, issued["phone"]["token"])
        check("recognition works with a managed token", status == 200 and body["text"] == "stub")
        status, body, _ = https_post(gw_port, "/v1/asr", wav, "hear_ut_wrong")
        check("inference with a wrong token is 401 with code and legacy error", status == 401
              and body["code"] == "TOKEN_INVALID" and body["error"] and body["request_id"])
        status, body, _ = https_post(gw_port, "/v1/translate", b"{}", None)
        check("inference without a token is 401", status == 401 and body["code"] == "TOKEN_REQUIRED")
        connection = http.client.HTTPConnection("127.0.0.1", gw_port, timeout=5)
        connection.request("POST", "/v1/asr", body=wav, headers={"X-Hear-Token": issued["phone"]["token"]})
        response = connection.getresponse()
        plain = json.loads(response.read())
        connection.close()
        check("plain HTTP inference is refused", response.status == 403 and plain["code"] == "HTTPS_REQUIRED")

        # 请求计数：推理和检查不产生清单请求
        before = store.list_gateways()["items"][0]["snapshot_requests"]
        started = time.monotonic()
        for _ in range(40):
            https_get(gw_port, "/v1/auth/check", issued["phone"]["token"])
            https_post(gw_port, "/v1/asr", wav, issued["phone"]["token"])
        elapsed = time.monotonic() - started
        after = store.list_gateways()["items"][0]["snapshot_requests"]
        check("80 checks/inferences cause only the scheduled snapshot requests",
              after - before <= int(elapsed / REFRESH) + 2, "%d requests in %.1fs" % (after - before, elapsed))

        # 撤销 / 改期 / 停用：下一轮同步后生效，网关不重启
        admin.call("POST", "/tokens/%s/revoke" % issued["ipad"]["token_id"], {"reason": "lost"})
        check("revocation is 204 and idempotent",
              admin.call("POST", "/tokens/%s/revoke" % issued["ipad"]["token_id"], {})[0] == 204)
        check("a revoked token is refused after the next sync",
              wait_for(lambda: https_get(gw_port, "/v1/auth/check", issued["ipad"]["token"])[1]["code"] == "TOKEN_REVOKED", REFRESH * 4))
        admin.call("PATCH", "/tokens/%s" % issued["later"]["token_id"], {"starts_at": iso(-5)})
        check("moving starts_at earlier takes effect after a sync",
              wait_for(lambda: https_get(gw_port, "/v1/auth/check", issued["later"]["token"])[0] == 200, REFRESH * 4))
        check("a short-lived token is refused once expires_at passes",
              wait_for(lambda: https_get(gw_port, "/v1/auth/check", issued["short"]["token"])[1].get("code") == "TOKEN_EXPIRED", 10))

        # --check-token 退出码
        code, output = run_check(gw_port, issued["phone"]["token"], gw_tmp)
        check("--check-token exits 0 for a valid token", code == 0, output)
        check("--check-token never prints the token", issued["phone"]["token"] not in output)
        check("--check-token shows network, model and token state",
              "网络连通" in output and "模型就绪" in output and "口令状态" in output)
        check("--check-token exits 3 for a wrong token", run_check(gw_port, "hear_ut_nope", gw_tmp)[0] == 3)
        check("--check-token exits 3 for an empty token", run_check(gw_port, "", gw_tmp)[0] == 3)
        check("--check-token exits 5 for an expired token", run_check(gw_port, issued["short"]["token"], gw_tmp)[0] == 5)
        check("--check-token exits 6 for a revoked token", run_check(gw_port, issued["ipad"]["token"], gw_tmp)[0] == 6)
        check("--check-token exits 2 when nothing listens", run_check(free_port(), "x", gw_tmp)[0] == 2)
        check("--check-token refuses plain http URLs", run_check(gw_port, "x", gw_tmp, "http://127.0.0.1:%d" % gw_port)[0] == 2)

        # 停用 / 重新启用
        admin.call("PATCH", "/users/" + uid, {"status": "disabled"})
        status, phone_meta, _ = admin.call("GET", "/tokens/" + issued["phone"]["token_id"])
        check("disabling a user revokes its tokens in the same transaction",
              phone_meta["status"] == "revoked" and phone_meta["revocation_reason"] == "user_disabled" and phone_meta["invalidated_at"])
        check("the gateway refuses the disabled user's token after a sync",
              wait_for(lambda: https_get(gw_port, "/v1/auth/check", issued["phone"]["token"])[1]["code"] == "TOKEN_REVOKED", REFRESH * 4))
        check("a disabled user cannot get new tokens", admin.call("POST", "/users/%s/tokens" % uid, {
            "label": "x", "gateway_id": "hear-test", "expires_at": iso(600)})[0] == 409)
        admin.call("PATCH", "/users/" + uid, {"status": "active"})
        time.sleep(REFRESH * 2)
        check("re-enabling a user does not restore old tokens",
              https_get(gw_port, "/v1/auth/check", issued["phone"]["token"])[1]["code"] == "TOKEN_REVOKED")
        status, fresh, _ = admin.call("POST", "/users/%s/tokens" % uid, {"label": "new phone", "gateway_id": "hear-test",
                                                                        "expires_at": iso(3600)})
        check("a new token works after the next sync without restarting Windows",
              status == 201 and wait_for(lambda: https_get(gw_port, "/v1/auth/check", fresh["token"])[0] == 200, REFRESH * 4))
        status, _, _ = admin.call("DELETE", "/users/" + uid)
        check("deleting a user is 204 and revokes its tokens", status == 204
              and admin.call("GET", "/tokens/" + fresh["token_id"])[1]["revocation_reason"] == "user_deleted")
        check("a deleted user stays queryable for audit", admin.call("GET", "/users/" + uid)[1]["status"] == "deleted")
        check("a deleted username can be reused", admin.call("POST", "/users", {"username": "bob"})[0] == 201)

        # 管理服务断开
        service.shutdown()
        service.server_close()
        check("over the staleness window without sync, inference returns 503",
              wait_for(lambda: https_post(gw_port, "/v1/asr", wav, fresh["token"])[1]["code"] == "AUTH_SERVICE_UNAVAILABLE", STALE + 6))
        _, health, _ = https_get(gw_port, "/health")
        check("/health stays 200 but shows auth_ready=false", health["auth_ready"] is False)
        check("--check-token exits 7 while the auth service is unavailable", run_check(gw_port, "x", gw_tmp)[0] == 7)
        service = serve()
        check("verification resumes automatically when the service returns",
              wait_for(lambda: https_get(gw_port, "/health")[1]["auth_ready"] is True, 15))
    finally:
        stop(gateway)

    # 冷启动：管理服务不可用时拒绝推理
    service.shutdown()
    service.server_close()
    cold_port = free_port()
    cold = start_gateway(gw_tmp, cold_port, managed_env)
    try:
        _, health, _ = https_get(cold_port, "/health")
        status, body, _ = https_post(cold_port, "/v1/asr", wav, "hear_ut_any")
        check("a cold start without the service refuses inference (503)",
              health["auth_ready"] is False and status == 503 and body["code"] == "AUTH_SERVICE_UNAVAILABLE")
    finally:
        stop(cold)

    # 旧网关（未接入托管鉴权）
    legacy_port = free_port()
    legacy = start_gateway(gw_tmp, legacy_port, {"HEAR_ASR_URL": "http://127.0.0.1:%d" % stub.server_port})
    try:
        check("/v1/auth/check is 404 on a gateway without managed auth",
              https_get(legacy_port, "/v1/auth/check", "x")[0] == 404)
        check("--check-token exits 7 when the target has no managed auth", run_check(legacy_port, "x", gw_tmp)[0] == 7)
    finally:
        stop(legacy)

    bad_port = free_port()
    broken = start_gateway(gw_tmp, bad_port, {"HEAR_AUTH_MODE": "managed", "HEAR_GATEWAY_ID": "hear-test"})
    check("an incomplete managed configuration stops the gateway with a clear error",
          broken.wait(timeout=10) != 0 and "HEAR_AUTH_API_URL" in open(os.path.join(gw_tmp, "gateway-%d.log" % bad_port),
                                                                        encoding="utf-8", errors="replace").read())
    stub.shutdown()

    events = store.list_audit(limit=200)["items"]
    dump = json.dumps(events, ensure_ascii=False)
    check("the audit log records revocations with before/after state",
          any(e["action"] == "token.revoke" and e["before"]["status"] == "active" and e["after"]["status"] == "revoked" for e in events))
    check("the audit log never contains raw tokens or credentials",
          not any(raw in dump for raw in raw_tokens + [credential, fresh["token"]]))
    logs = "".join(open(os.path.join(gw_tmp, name), encoding="utf-8", errors="replace").read()
                   for name in os.listdir(gw_tmp) if name.endswith(".log"))
    check("gateway logs never contain raw tokens or the gateway credential",
          not any(raw in logs for raw in raw_tokens + [credential, fresh["token"]]))


def main():
    tmp = tempfile.mkdtemp(prefix="hear-token-")
    try:
        unit_authenticator()
        unit_store(tmp)
        end_to_end(tmp)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    print("\npassed %d, failed %d" % (len(PASSED), len(FAILED)))
    for name in FAILED:
        print("  failed: %s" % name)
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
