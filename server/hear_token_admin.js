"use strict";
// 听见 Token 管理后台。只与同源的 /admin/api/v1 通信；所有用户数据都用 textContent 写入页面。
(function () {
  const API = "/admin/api/v1";
  const state = { csrf: null, admin: null, user: null, gateways: [], cursors: {}, editingToken: null, editingUser: null };
  const $ = (id) => document.getElementById(id);

  // ---------------------------------------------------------------- 工具
  function el(tag, props, ...children) {
    const node = document.createElement(tag);
    for (const [key, value] of Object.entries(props || {})) {
      if (key === "class") node.className = value;
      else if (key.startsWith("on")) node.addEventListener(key.slice(2), value);
      else if (value !== undefined && value !== null) node.setAttribute(key, value);
    }
    for (const child of children.flat()) {
      if (child === null || child === undefined) continue;
      node.append(child instanceof Node ? child : document.createTextNode(String(child)));
    }
    return node;
  }
  const fmt = (iso) => (iso ? new Date(iso).toLocaleString() : "—");
  function pill(status, kind) {
    const names = kind === "user"
      ? { active: "启用", disabled: "停用", deleted: "已删除" }
      : { active: "可用", scheduled: "未生效", expired: "已到期", revoked: "已撤销" };
    return el("span", { class: "pill " + status, title: status }, names[status] || status);
  }
  // datetime-local（浏览器时区）⇄ 带时区的 ISO 8601（API 统一用 UTC）
  function toLocalInput(iso) {
    const d = iso ? new Date(iso) : new Date();
    const pad = (n) => String(n).padStart(2, "0");
    return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}:${pad(d.getSeconds())}`;
  }
  function fromLocalInput(value) {
    if (!value) return null;
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) throw new Error("时间格式不对");
    return d.toISOString();
  }
  let toastTimer = null;
  function toast(message, bad) {
    const node = $("toast");
    node.textContent = message;
    node.className = "toast" + (bad ? " bad" : "");
    node.hidden = false;
    clearTimeout(toastTimer);
    toastTimer = setTimeout(() => (node.hidden = true), 3200);
  }

  async function api(method, path, body) {
    const headers = { Accept: "application/json" };
    if (body !== undefined) headers["Content-Type"] = "application/json";
    if (method !== "GET" && state.csrf) headers["X-CSRF-Token"] = state.csrf;
    const response = await fetch(API + path, {
      method, headers, credentials: "same-origin", cache: "no-store",
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (response.status === 204) return null;
    let data = null;
    try { data = await response.json(); } catch (_) { data = null; }
    if (!response.ok) {
      if (response.status === 401 && path !== "/session") showLogin();
      const error = new Error((data && data.message) || "请求失败（HTTP " + response.status + "）");
      error.code = data && data.code;
      error.field = data && data.field;
      error.status = response.status;
      throw error;
    }
    return data;
  }
  const qs = (params) => {
    const entries = Object.entries(params).filter(([, v]) => v !== undefined && v !== null && v !== "");
    return entries.length ? "?" + new URLSearchParams(entries).toString() : "";
  };

  // ---------------------------------------------------------------- 视图切换
  const views = ["login", "users", "user", "audit", "gateways"];
  function show(view) {
    for (const name of views) $("view-" + name).hidden = name !== view;
    document.querySelectorAll(".tab").forEach((tab) => tab.classList.toggle("active",
      tab.dataset.view === view || (view === "user" && tab.dataset.view === "users")));
  }
  function showLogin() {
    state.csrf = null; state.admin = null;
    $("nav").hidden = true; $("who").hidden = true;
    show("login");
  }
  function signedIn(session) {
    state.csrf = session.csrf_token;
    state.admin = session.admin;
    $("who-name").textContent = session.admin.username;
    $("who-role").textContent = session.admin.role === "admin" ? "管理员" : "只读";
    document.body.classList.toggle("readonly", session.admin.role !== "admin");
    $("nav").hidden = false; $("who").hidden = false;
    loadGateways().catch(() => {});
    openUsers();
  }

  // ---------------------------------------------------------------- 登录
  $("login-form").addEventListener("submit", async (event) => {
    event.preventDefault();
    const form = event.target;
    $("login-error").textContent = "";
    try {
      const session = await api("POST", "/session", { username: form.username.value, password: form.password.value });
      form.password.value = "";
      signedIn(session);
    } catch (error) {
      $("login-error").textContent = error.message;
    }
  });
  $("logout").addEventListener("click", async () => {
    try { await api("DELETE", "/session"); } catch (_) { /* 会话可能已过期 */ }
    showLogin();
  });
  document.querySelectorAll(".tab").forEach((tab) => tab.addEventListener("click", () => {
    if (tab.dataset.view === "users") openUsers();
    if (tab.dataset.view === "audit") openAudit();
    if (tab.dataset.view === "gateways") openGateways();
  }));

  // ---------------------------------------------------------------- 用户列表
  let searchTimer = null;
  $("user-search").addEventListener("input", () => { clearTimeout(searchTimer); searchTimer = setTimeout(() => loadUsers(false), 250); });
  $("user-status").addEventListener("change", () => loadUsers(false));
  $("user-more").addEventListener("click", () => loadUsers(true));
  function openUsers() { show("users"); loadUsers(false); }

  async function loadUsers(more) {
    const body = $("user-rows");
    const page = await api("GET", "/users" + qs({
      search: $("user-search").value.trim(), status: $("user-status").value, limit: 50,
      cursor: more ? state.cursors.users : undefined,
    }));
    if (!more) body.replaceChildren();
    for (const user of page.items) {
      body.append(el("tr", { class: "click", onclick: () => openUser(user.user_id) },
        el("td", { class: "mono" }, user.username),
        el("td", {}, user.display_name || "—"),
        el("td", {}, pill(user.status, "user")),
        el("td", {}, `${user.active_token_count} / ${user.token_count}`),
        el("td", {}, fmt(user.updated_at))));
    }
    if (!body.children.length) body.append(el("tr", {}, el("td", { colspan: 5, class: "empty" }, "没有用户")));
    state.cursors.users = page.next_cursor;
    $("user-more").hidden = !page.next_cursor;
  }

  // ---------------------------------------------------------------- 用户详情
  $("back-users").addEventListener("click", openUsers);
  $("token-status").addEventListener("change", () => loadTokens(false));
  $("token-more").addEventListener("click", () => loadTokens(true));

  async function openUser(userId) {
    const user = await api("GET", "/users/" + encodeURIComponent(userId));
    state.user = user;
    show("user");
    $("u-title").textContent = user.display_name ? `${user.display_name}（${user.username}）` : user.username;
    $("u-status").replaceWith(Object.assign(pill(user.status, "user"), { id: "u-status" }));
    $("u-id").textContent = user.user_id;
    $("u-notes").textContent = user.notes || "—";
    $("u-created").textContent = fmt(user.created_at);
    $("u-updated").textContent = fmt(user.updated_at);
    $("u-disabled").textContent = fmt(user.disabled_at);
    const deleted = user.status === "deleted";
    $("u-edit").disabled = deleted;
    $("u-delete").disabled = deleted;
    $("u-toggle").disabled = deleted;
    $("u-toggle").textContent = user.status === "active" ? "停用" : "重新启用";
    $("token-new").disabled = user.status !== "active";
    $("token-new").title = user.status === "active" ? "" : "用户启用后才能签发 Token";
    loadTokens(false);
  }

  async function loadTokens(more) {
    const body = $("token-rows");
    const page = await api("GET", `/users/${encodeURIComponent(state.user.user_id)}/tokens` + qs({
      status: $("token-status").value, limit: 50, cursor: more ? state.cursors.tokens : undefined,
    }));
    if (!more) body.replaceChildren();
    for (const token of page.items) {
      const editable = token.status === "active" || token.status === "scheduled";
      const actions = el("td", { class: "write" });
      if (editable) {
        actions.append(el("button", { onclick: () => editToken(token) }, "修改"), " ",
          el("button", { class: "danger", onclick: () => revokeToken(token) }, "撤销"));
      }
      body.append(el("tr", { title: token.token_id },
        el("td", {}, token.label, el("div", { class: "hint mono" }, token.token_id)),
        el("td", { class: "mono" }, "…" + token.token_suffix),
        el("td", { class: "mono" }, token.gateway_id),
        el("td", {}, pill(token.status), token.revocation_reason ? el("div", { class: "hint" }, token.revocation_reason) : null),
        el("td", {}, fmt(token.starts_at)),
        el("td", {}, fmt(token.expires_at)),
        el("td", {}, fmt(token.invalidated_at)),
        actions));
    }
    if (!body.children.length) body.append(el("tr", {}, el("td", { colspan: 8, class: "empty" }, "没有 Token")));
    state.cursors.tokens = page.next_cursor;
    $("token-more").hidden = !page.next_cursor;
  }

  // 用户新增 / 编辑
  $("user-new").addEventListener("click", () => openUserForm(null));
  $("u-edit").addEventListener("click", () => openUserForm(state.user));
  function openUserForm(user) {
    state.editingUser = user;
    const form = $("user-form");
    form.reset();
    $("user-form-title").textContent = user ? "编辑用户" : "新增用户";
    $("user-form-error").textContent = "";
    if (user) { form.username.value = user.username; form.display_name.value = user.display_name; form.notes.value = user.notes; }
    $("dlg-user").showModal();
  }
  $("user-form").addEventListener("submit", async (event) => {
    if (event.submitter && event.submitter.value === "cancel") return;
    event.preventDefault();
    const form = event.target;
    const body = { username: form.username.value.trim(), display_name: form.display_name.value, notes: form.notes.value };
    try {
      const saved = state.editingUser
        ? await api("PATCH", "/users/" + encodeURIComponent(state.editingUser.user_id), body)
        : await api("POST", "/users", body);
      $("dlg-user").close();
      toast(state.editingUser ? "已保存" : "已新增用户");
      openUser(saved.user_id);
    } catch (error) {
      $("user-form-error").textContent = error.message;
    }
  });
  $("u-toggle").addEventListener("click", async () => {
    const disabling = state.user.status === "active";
    if (disabling && !confirm("停用后，该用户所有可用和未生效的 Token 会立即撤销（重新启用不会恢复旧 Token）。继续？")) return;
    try {
      await api("PATCH", "/users/" + encodeURIComponent(state.user.user_id), { status: disabling ? "disabled" : "active" });
      toast(disabling ? "已停用，相关 Token 已撤销" : "已重新启用，请签发新 Token");
      openUser(state.user.user_id);
    } catch (error) { toast(error.message, true); }
  });
  $("u-delete").addEventListener("click", async () => {
    if (!confirm("删除（逻辑删除）后该用户的可用和未生效 Token 立即撤销，操作记录保留。继续？")) return;
    try {
      await api("DELETE", "/users/" + encodeURIComponent(state.user.user_id));
      toast("已删除");
      openUsers();
    } catch (error) { toast(error.message, true); }
  });

  // ---------------------------------------------------------------- Token 签发 / 修改 / 撤销
  async function loadGateways() {
    const page = await api("GET", "/gateways");
    state.gateways = page.items;
    return page.items;
  }
  function tzHint() {
    const zone = Intl.DateTimeFormat().resolvedOptions().timeZone || "本机时区";
    $("tz-hint").textContent = `按浏览器时区（${zone}）填写，提交时换算成 UTC；有效条件：开始 ≤ 现在 < 结束。`;
  }
  $("token-new").addEventListener("click", async () => {
    const gateways = await loadGateways();
    if (!gateways.length) { toast("请先在「网关」页登记网关", true); return; }
    state.editingToken = null;
    const form = $("token-form");
    form.reset();
    $("token-form-title").textContent = "签发 Token";
    $("token-gw-label").hidden = false;
    form.gateway_id.replaceChildren(...gateways.map((g) => el("option", { value: g.gateway_id }, g.name ? `${g.gateway_id}（${g.name}）` : g.gateway_id)));
    form.gateway_id.required = true;
    const now = new Date();
    form.starts_at.value = toLocalInput(now.toISOString());
    form.expires_at.value = toLocalInput(new Date(now.getTime() + 30 * 86400000).toISOString());
    $("token-form-error").textContent = "";
    tzHint();
    $("dlg-token").showModal();
  });
  function editToken(token) {
    state.editingToken = token;
    const form = $("token-form");
    form.reset();
    $("token-form-title").textContent = "修改 Token：" + token.label;
    $("token-gw-label").hidden = true;
    form.gateway_id.required = false;
    form.label.value = token.label;
    form.starts_at.value = toLocalInput(token.starts_at);
    form.expires_at.value = toLocalInput(token.expires_at);
    $("token-form-error").textContent = "";
    tzHint();
    $("dlg-token").showModal();
  }
  $("token-form").addEventListener("submit", async (event) => {
    if (event.submitter && event.submitter.value === "cancel") return;
    event.preventDefault();
    const form = event.target;
    try {
      const body = { label: form.label.value.trim(), starts_at: fromLocalInput(form.starts_at.value), expires_at: fromLocalInput(form.expires_at.value) };
      if (state.editingToken) {
        await api("PATCH", "/tokens/" + encodeURIComponent(state.editingToken.token_id), body);
        $("dlg-token").close();
        toast("已修改，网关下一轮同步（约 30 秒）后生效");
      } else {
        body.gateway_id = form.gateway_id.value;
        const issued = await api("POST", `/users/${encodeURIComponent(state.user.user_id)}/tokens`, body);
        $("dlg-token").close();
        showSecret("Token 已签发：" + issued.label, issued.token,
          "Token 原文只显示这一次，关闭后无法再查看。请通过安全渠道发给用户，在 App「访问口令」中填写。");
      }
      loadTokens(false);
    } catch (error) {
      $("token-form-error").textContent = error.message;
    }
  });
  function revokeToken(token) {
    state.editingToken = token;
    $("revoke-form").reset();
    $("revoke-what").textContent = `${token.label}（…${token.token_suffix}，${token.token_id}）`;
    $("dlg-revoke").showModal();
  }
  $("revoke-form").addEventListener("submit", async (event) => {
    if (event.submitter && event.submitter.value === "cancel") return;
    event.preventDefault();
    try {
      const reason = event.target.reason.value.trim();
      await api("POST", "/tokens/" + encodeURIComponent(state.editingToken.token_id) + "/revoke", reason ? { reason } : {});
      $("dlg-revoke").close();
      toast("已撤销，网关下一轮同步（约 30 秒）后拒绝");
      loadTokens(false);
    } catch (error) { toast(error.message, true); }
  });

  // 一次性展示原文：关闭时从页面清掉
  function showSecret(title, secret, warning) {
    $("secret-title").textContent = title;
    $("secret-warning").textContent = warning;
    $("secret-value").textContent = secret;
    $("dlg-secret").showModal();
  }
  $("secret-copy").addEventListener("click", async () => {
    try { await navigator.clipboard.writeText($("secret-value").textContent); toast("已复制"); }
    catch (_) { toast("浏览器不允许自动复制，请手动选中复制", true); }
  });
  $("secret-close").addEventListener("click", () => $("dlg-secret").close());
  $("dlg-secret").addEventListener("close", () => { $("secret-value").textContent = ""; });

  // ---------------------------------------------------------------- 审计
  function openAudit() { show("audit"); loadAudit(false); }
  $("audit-filter").addEventListener("submit", (event) => { event.preventDefault(); loadAudit(false); });
  $("audit-more").addEventListener("click", () => loadAudit(true));
  function diffText(before, after) {
    if (!before && !after) return "";
    const keys = new Set([...Object.keys(before || {}), ...Object.keys(after || {})]);
    const parts = [];
    for (const key of keys) {
      const a = before ? before[key] : undefined;
      const b = after ? after[key] : undefined;
      if (JSON.stringify(a) === JSON.stringify(b) || key === "updated_at") continue;
      parts.push(el("div", {}, el("b", {}, key), ": ", a === undefined ? "" : String(a), " → ", b === undefined ? "" : String(b)));
    }
    return parts;
  }
  async function loadAudit(more) {
    const form = $("audit-filter");
    let since, until;
    try { since = fromLocalInput(form.since.value); until = fromLocalInput(form.until.value); }
    catch (error) { toast(error.message, true); return; }
    const page = await api("GET", "/audit-events" + qs({
      action: form.action.value, user_id: form.user_id.value.trim(), token_id: form.token_id.value.trim(),
      since, until, limit: 50, cursor: more ? state.cursors.audit : undefined,
    }));
    const body = $("audit-rows");
    if (!more) body.replaceChildren();
    for (const event of page.items) {
      body.append(el("tr", {},
        el("td", {}, fmt(event.occurred_at)),
        el("td", {}, event.actor.username || event.actor.id, el("div", { class: "hint" }, event.actor.type)),
        el("td", { class: "mono" }, event.action),
        el("td", { class: "mono" }, event.target_id, event.user_id && event.user_id !== event.target_id ? el("div", { class: "hint" }, event.user_id) : null),
        el("td", { class: "diff" }, diffText(event.before, event.after))));
    }
    if (!body.children.length) body.append(el("tr", {}, el("td", { colspan: 5, class: "empty" }, "没有记录")));
    state.cursors.audit = page.next_cursor;
    $("audit-more").hidden = !page.next_cursor;
  }

  // ---------------------------------------------------------------- 网关
  async function openGateways() {
    show("gateways");
    const gateways = await loadGateways();
    const body = $("gw-rows");
    body.replaceChildren();
    for (const gw of gateways) {
      body.append(el("tr", {},
        el("td", { class: "mono" }, gw.gateway_id),
        el("td", {}, gw.name || "—"),
        el("td", {}, String(gw.revision)),
        el("td", {}, String(gw.snapshot_requests)),
        el("td", {}, fmt(gw.last_snapshot_at)),
        el("td", {}, fmt(gw.credential_rotated_at)),
        el("td", { class: "write" }, el("button", { onclick: () => rotateGateway(gw) }, "轮换凭据"))));
    }
    if (!body.children.length) body.append(el("tr", {}, el("td", { colspan: 7, class: "empty" }, "还没有登记网关")));
  }
  $("gw-new").addEventListener("click", () => { $("gw-form").reset(); $("gw-form-error").textContent = ""; $("dlg-gateway").showModal(); });
  $("gw-form").addEventListener("submit", async (event) => {
    if (event.submitter && event.submitter.value === "cancel") return;
    event.preventDefault();
    const form = event.target;
    try {
      const gw = await api("POST", "/gateways", { gateway_id: form.gateway_id.value.trim(), name: form.name.value });
      $("dlg-gateway").close();
      showSecret("网关凭据：" + gw.gateway_id, gw.credential,
        "网关凭据只显示这一次。保存到 Windows 网关上受权限保护的文件，并把 HEAR_GATEWAY_CREDENTIAL_FILE 指向它。");
      openGateways();
    } catch (error) { $("gw-form-error").textContent = error.message; }
  });
  async function rotateGateway(gw) {
    if (!confirm(`轮换后 ${gw.gateway_id} 的旧凭据立即失效，网关在更新凭据文件并重启前会无法同步。继续？`)) return;
    try {
      const result = await api("POST", "/gateways/" + encodeURIComponent(gw.gateway_id) + "/rotate-credential");
      showSecret("新网关凭据：" + gw.gateway_id, result.credential, "新凭据只显示这一次。更新网关凭据文件后重启网关。");
      openGateways();
    } catch (error) { toast(error.message, true); }
  }

  // ---------------------------------------------------------------- 启动
  api("GET", "/session").then(signedIn).catch(showLogin);
})();
