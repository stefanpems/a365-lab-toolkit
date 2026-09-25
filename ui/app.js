/* global msal */
(() => {
  "use strict";

  const cfg = window.APP_CONFIG;
  const agents = cfg.agents;
  const redirectUri = window.location.origin;

  // Fresh session nonce per page load. Foundry Invocations sessions are pinned to the
  // agent version active when the session was created; rotating the id per load ensures
  // the latest deployed version is always served. The handler is stateless, so there is
  // no conversation-memory downside.
  const SESSION_NONCE = ((self.crypto && crypto.randomUUID)
    ? crypto.randomUUID() : Math.random().toString(36).slice(2)).replace(/-/g, "").slice(0, 8);

  const pca = new msal.PublicClientApplication({
    auth: {
      clientId: cfg.msal.clientId,
      authority: cfg.msal.authority,
      redirectUri,
      navigateToLoginRequestUrl: false
    },
    cache: {
      cacheLocation: "localStorage",
      temporaryCacheLocation: "localStorage"
    },
    system: {
      loggerOptions: {
        logLevel: msal.LogLevel.Info,
        loggerCallback: (level, message, containsPii) => {
          if (!containsPii) console.log("MSAL", level, message);
        }
      }
    }
  });

  const loginRequest = { scopes: ["openid", "profile"] };

  // Per-agent conversation history: { [agentId]: [{ role, content }] }
  const histories = {};
  agents.forEach(a => (histories[a.id] = []));

  // Short conversation memory: every request carries the last MEMORY_TURNS exchanges (user +
  // assistant) of THIS tab, so the agent can resolve follow-ups ("and its most populous district?")
  // with no server-side store. The agents re-validate and re-cap it (roles user/assistant only).
  const MEMORY_TURNS = 3;
  const MEMORY_MAX_CHARS = 4000;
  function recentHistory(agentId) {
    // All messages BEFORE the one being sent (sendMessage pushes it first).
    const prior = histories[agentId].slice(0, -1).slice(-2 * MEMORY_TURNS)
      .map(h => ({ role: h.role, content: String(h.content).slice(0, MEMORY_MAX_CHARS) }));
    while (prior.length && prior[0].role !== "user") prior.shift();
    return prior;
  }
  // Responses-API input: prior exchanges as message items + the (possibly enriched) new message.
  function responsesInput(history, text) {
    if (!history || !history.length) return text;
    return history.map(h => ({ type: "message", role: h.role, content: h.content }))
      .concat([{ type: "message", role: "user", content: text }]);
  }

  const el = {
    loginView: document.getElementById("login-view"),
    appView: document.getElementById("app-view"),
    loginBtn: document.getElementById("login-btn"),
    loginError: document.getElementById("login-error"),
    logoutBtn: document.getElementById("logout-btn"),
    userName: document.getElementById("user-name"),
    tabs: document.getElementById("tabs"),
    panels: document.getElementById("panels")
  };

  function getAccount() {
    return pca.getActiveAccount() || pca.getAllAccounts()[0] || null;
  }

  function clearStaleInteraction() {
    try {
      [window.sessionStorage, window.localStorage].forEach(store => {
        for (let i = store.length - 1; i >= 0; i--) {
          const k = store.key(i);
          if (k && k.indexOf("interaction.status") !== -1) store.removeItem(k);
        }
      });
    } catch (e) { /* ignore */ }
  }

  async function init() {
    await pca.initialize();
    const hash = window.location.hash || "";
    const hadAuthResponse = hash.indexOf("code=") !== -1 || hash.indexOf("error=") !== -1;
    const authParams = new URLSearchParams(hash.replace(/^#/, ""));
    try {
      const result = await pca.handleRedirectPromise();
      if (result && result.account) {
        pca.setActiveAccount(result.account);
      }
      if (window.location.hash) {
        history.replaceState(null, "", window.location.pathname + window.location.search);
      }
    } catch (e) {
      showLoginError("ERR " + (e.errorCode ? e.errorCode + ": " : "") + (e.message || e));
    }

    const account = getAccount();
    if (account) {
      pca.setActiveAccount(account);
      showApp(account);
    } else {
      showLogin();
      if (authParams.has("error") && !el.loginError.textContent) {
        showLoginError("Entra error: " + authParams.get("error") + ". " + (authParams.get("error_description") || ""));
      } else if (hadAuthResponse && !el.loginError.textContent) {
        showLoginError("Returned from Entra, but MSAL did not create an account. Redirect URI used: " + redirectUri);
      }
    }
  }

  function showLogin() {
    el.appView.hidden = true;
    el.loginView.hidden = false;
  }

  function showLoginError(msg) {
    el.loginError.textContent = msg || "";
  }

  function showApp(account) {
    el.loginView.hidden = true;
    el.appView.hidden = false;
    el.userName.textContent = account.name || account.username || "";
    if (el.tabs.childElementCount === 0) {
      buildUI();
    }
  }

  async function signIn() {
    showLoginError("");
    clearStaleInteraction();
    try {
      await pca.loginRedirect(loginRequest);
    } catch (e) {
      if (e && e.errorCode === "interaction_in_progress") {
        clearStaleInteraction();
        await pca.loginRedirect(loginRequest);
      } else {
        showLoginError(e.message || String(e));
      }
    }
  }

  el.loginBtn.addEventListener("click", signIn);

  el.logoutBtn.addEventListener("click", () => {
    pca.logoutRedirect({ postLogoutRedirectUri: redirectUri });
  });

  // --- Build vertical tabs + one chat panel per agent ---
  // A tab is rendered only when its agent is live: entries are hidden while `enabled === false`
  // (the scaffolder ships every tab that way) and shown once the integration step flips the flag
  // to true. Entries without the flag are treated as live (backward-compatible with older configs).
  function buildUI() {
    const liveAgents = agents.filter(a => a.enabled !== false);
    if (liveAgents.length === 0) {
      el.tabs.innerHTML = '<p class="side-empty">No agents are live yet.</p>';
      el.panels.innerHTML =
        '<div class="panels-empty">Agents appear in the left sidebar as they are deployed and wired. '
        + 'Come back after the first one goes live.</div>';
      return;
    }
    liveAgents.forEach((agent, index) => {
      const tab = document.createElement("button");
      tab.className = "tab" + (index === 0 ? " active" : "");
      tab.dataset.agent = agent.id;
      tab.innerHTML =
        `<span class="tab-name">${escapeHtml(agent.name)}</span>` +
        (agent.description ? `<span class="tab-desc">${escapeHtml(agent.description)}</span>` : "");
      tab.addEventListener("click", () => activateAgent(agent.id));
      el.tabs.appendChild(tab);

      const panel = document.createElement("section");
      panel.className = "panel" + (index === 0 ? " active" : "");
      panel.dataset.agent = agent.id;
      panel.innerHTML = `
        <div class="messages" id="messages-${agent.id}">
          <div class="empty-hint">Start chatting with <strong>${escapeHtml(agent.name)}</strong>.</div>
        </div>
        <form class="composer" data-agent="${agent.id}">
          <textarea rows="1" placeholder="Type a message…" required></textarea>
          <button type="submit">Send</button>
        </form>`;
      el.panels.appendChild(panel);

      const form = panel.querySelector(".composer");
      const textarea = form.querySelector("textarea");
      textarea.addEventListener("keydown", ev => {
        if (ev.key === "Enter" && !ev.shiftKey) {
          ev.preventDefault();
          form.requestSubmit();
        }
      });
      textarea.addEventListener("input", () => {
        textarea.style.height = "auto";
        textarea.style.height = Math.min(textarea.scrollHeight, 160) + "px";
      });
      form.addEventListener("submit", ev => {
        ev.preventDefault();
        sendMessage(agent, textarea);
      });
    });
  }

  function activateAgent(agentId) {
    el.tabs.querySelectorAll(".tab").forEach(t =>
      t.classList.toggle("active", t.dataset.agent === agentId));
    el.panels.querySelectorAll(".panel").forEach(p =>
      p.classList.toggle("active", p.dataset.agent === agentId));
  }

  async function acquireToken(scope) {
    const account = getAccount();
    const request = { scopes: [scope], account };
    try {
      const r = await pca.acquireTokenSilent(request);
      return r.accessToken;
    } catch (e) {
      // Interaction required — fall back to a full-page redirect (no popup / COOP issues).
      await pca.acquireTokenRedirect(request);
      return null;
    }
  }

  async function sendMessage(agent, textarea) {
    const message = textarea.value.trim();
    if (!message) return;

    const messagesEl = document.getElementById(`messages-${agent.id}`);
    const hint = messagesEl.querySelector(".empty-hint");
    if (hint) hint.remove();

    appendMessage(messagesEl, "user", message);
    histories[agent.id].push({ role: "user", content: message });
    textarea.value = "";
    textarea.style.height = "auto";

    const form = textarea.closest(".composer");
    const sendBtn = form.querySelector("button");
    sendBtn.disabled = true;
    const thinking = appendMessage(messagesEl, "thinking", "The agent is thinking…");

    try {
      const history = recentHistory(agent.id);
      const reply = agent.kind === "foundry-invocations"
        ? await callFoundryInvocations(agent, message, history)
        : agent.kind === "foundry-responses"
        ? await callFoundryResponses(agent, message, history)
        : agent.kind === "foundry-prompt"
        ? await callFoundryPrompt(agent, message, history)
        : await callAcaChat(agent, message, history);

      thinking.remove();
      if (reply === null) return; // token interaction (redirect) in progress

      appendMessage(messagesEl, "agent", reply);
      histories[agent.id].push({ role: "assistant", content: reply });
    } catch (e) {
      thinking.remove();
      // Keep the remembered window consistent: drop the unanswered user message.
      const h = histories[agent.id];
      if (h.length && h[h.length - 1].role === "user") h.pop();
      appendMessage(messagesEl, "error", e.message || String(e));
    } finally {
      sendBtn.disabled = false;
      textarea.focus();
    }
  }

  // ACA-hosted agents: /chat endpoint, single bearer token, {message, history} -> {reply}.
  async function callAcaChat(agent, message, history) {
    const token = await acquireToken(agent.scope);
    if (!token) return null; // redirect in progress

    // OBO agents with attached custom MCP servers: also acquire a delegated USER token for each
    // custom server's audience and pass them, so the agent reaches the BYO ext_* servers through
    // the Agent 365 gateway AS THE USER — matching the Power Platform connection the user created
    // for each server (that identity match is why OBO works and DW/S2S do not).
    const tokens = {};
    if (agent.customScopes) {
      for (const [audience, scope] of Object.entries(agent.customScopes)) {
        const ct = await acquireToken(scope);
        if (ct === null) return null; // token interaction (redirect) in progress
        tokens[audience] = ct;
      }
    }

    const body = { message, history };
    if (Object.keys(tokens).length) body.tokens = tokens;

    const res = await fetch(agent.apiBase.replace(/\/$/, "") + "/chat", {
      method: "POST",
      headers: { "Authorization": "Bearer " + token, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Error ${res.status}. ${text}`.trim());
    }
    const data = await res.json();
    return data.reply ?? data.Reply ?? "(no response)";
  }

  // Foundry Hosted Agent (Invocations protocol): two tokens.
  //  - endpointScope token -> Authorization header (authenticates to the Foundry gateway)
  //  - mailScope token (OBO only) -> body.mail_token (delegated Mail token for the Mail MCP)
  // Body: { message, history?, mail_token? }  ->  Response: { response }.
  async function callFoundryInvocations(agent, message, history) {
    const endpointToken = await acquireToken(agent.endpointScope);
    if (!endpointToken) return null; // redirect in progress

    const body = { message };
    if (history && history.length) body.history = history;
    if (agent.mailScope) {
      const mailToken = await acquireToken(agent.mailScope);
      if (!mailToken) return null; // redirect in progress
      body.mail_token = mailToken;
    }

    // OBO agents with attached custom MCP servers: acquire a delegated USER token per custom
    // audience and pass them as `tokens` so the agent reaches the BYO ext_* servers through the
    // Agent 365 gateway AS THE USER (matching the user's Power Platform connection).
    const tokens = {};
    if (agent.customScopes) {
      for (const [audience, scope] of Object.entries(agent.customScopes)) {
        const ct = await acquireToken(scope);
        if (ct === null) return null; // token interaction (redirect) in progress
        tokens[audience] = ct;
      }
    }
    if (Object.keys(tokens).length) body.tokens = tokens;

    // so a fixed/shared id would give "session_not_accessible" (403) to other users.
    const acct = getAccount();
    const uid = (acct && (acct.localAccountId || acct.homeAccountId)) || "anon";
    const sid = (agent.sessionPrefix || "obo") + "-" + uid + "-" + SESSION_NONCE;
    const url = agent.endpoint + "&agent_session_id=" + encodeURIComponent(sid);
    const doPost = () => fetch(url, {
      method: "POST",
      headers: { "Authorization": "Bearer " + endpointToken, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    // The Foundry gateway (preview) occasionally returns a transient 5xx; retry once.
    let res = await doPost();
    if (res.status >= 500) {
      await new Promise(r => setTimeout(r, 1200));
      res = await doPost();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Error ${res.status}. ${text}`.trim());
    }
    const data = await res.json();
    return data.response ?? data.reply ?? "(no response)";
  }

  // Foundry Hosted Agent (Responses protocol): OpenAI-compatible /responses.
  //  - endpointScope token -> Authorization header (authenticates to the Foundry gateway)
  //  - no user/mail token (the agent acts with its own identity)
  // Body: { input, stream:false }  ->  Response: { status, output[].content[].text }.
  async function callFoundryResponses(agent, message, history) {
    const endpointToken = await acquireToken(agent.endpointScope);
    if (!endpointToken) return null; // redirect in progress

    // The S2S agent acts with its OWN identity and never receives the user token, so the
    // SPA passes the signed-in user's verified profile (from the MSAL account) as context
    // in the input. The UI still shows the original message; only the sent input is enriched.
    const acct = getAccount();
    const who = acct ? (acct.name || acct.username || "") : "";
    const upn = acct && acct.username ? acct.username : "";
    const input = who
      ? "Verified sign-in context: the signed-in user's name is \"" + who + "\""
        + (upn ? " (username/email: " + upn + ")" : "")
        + ". Use this information to personalize your answers and to respond to "
        + "questions about who the user is or what their name is.\n\nUser message:\n" + message
      : message;

    const doPost = () => fetch(agent.endpoint, {
      method: "POST",
      headers: { "Authorization": "Bearer " + endpointToken, "Content-Type": "application/json" },
      body: JSON.stringify({ input: responsesInput(history, input), stream: false })
    });
    let res = await doPost();
    if (res.status >= 500) {
      await new Promise(r => setTimeout(r, 1200));
      res = await doPost();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Error ${res.status}. ${text}`.trim());
    }
    const data = await res.json();
    // The Responses API returns 200 with a status; a failed run carries an error object.
    if (data.status && data.status !== "completed") {
      throw new Error("Agent error: " + ((data.error && data.error.message) || data.status));
    }
    return extractResponsesText(data);
  }

  // Foundry DECLARATIVE (prompt) agent — project-level Responses API with agent_reference.
  //  - endpointScope token -> Authorization header (authenticates to the Foundry project)
  //  - mailScope token (OBO) -> body.structured_inputs.mail_token, which fills the Mail MCP
  //    Authorization header server-side, so mail is sent from the signed-in user's mailbox.
  // Body: { input, agent_reference, structured_inputs? }  ->  Response: OpenAI Responses shape.
  async function callFoundryPrompt(agent, message, history) {
    const endpointToken = await acquireToken(agent.endpointScope);
    if (!endpointToken) return null; // redirect in progress

    // A prompt agent has no server-side code to decode the caller's token, and the mail_token
    // is only used server-side as the Mail MCP Authorization header (never seen by the LLM).
    // So, like the S2S Foundry tab, pass the signed-in user's verified profile as context in
    // the input so the agent can answer "who am I / what's my name".
    const acct = getAccount();
    const who = acct ? (acct.name || acct.username || "") : "";
    const upn = acct && acct.username ? acct.username : "";
    const input = who
      ? "Verified sign-in context: the signed-in user's name is \"" + who + "\""
        + (upn ? " (username/email: " + upn + ")" : "")
        + ". Use this information to personalize your answers and to respond to "
        + "questions about who the user is or what their name is.\n\nUser message:\n" + message
      : message;

    const body = {
      input: responsesInput(history, input),
      agent_reference: { name: agent.agentName, type: "agent_reference" }
    };
    const structuredInputs = {};
    if (agent.mailScope) {
      const mailToken = await acquireToken(agent.mailScope);
      if (!mailToken) return null; // redirect in progress
      structuredInputs.mail_token = "Bearer " + mailToken;
    }
    // Custom (BYO) MCP servers: one delegated token per structured input name (config.js
    // obo-fd "customInputs": { <input>: <scope> }) so the declarative agent reaches each
    // server through the Agent 365 gateway on behalf of the signed-in user.
    if (agent.customInputs) {
      for (const [inputName, scope] of Object.entries(agent.customInputs)) {
        const ct = await acquireToken(scope);
        if (!ct) return null; // redirect in progress
        structuredInputs[inputName] = "Bearer " + ct;
      }
    }
    if (Object.keys(structuredInputs).length) body.structured_inputs = structuredInputs;

    const doPost = () => fetch(agent.endpoint, {
      method: "POST",
      headers: { "Authorization": "Bearer " + endpointToken, "Content-Type": "application/json" },
      body: JSON.stringify(body)
    });
    let res = await doPost();
    if (res.status >= 500) {
      await new Promise(r => setTimeout(r, 1200));
      res = await doPost();
    }
    if (!res.ok) {
      const text = await res.text().catch(() => "");
      throw new Error(`Error ${res.status}. ${text}`.trim());
    }
    const data = await res.json();
    if (data.status && data.status !== "completed") {
      throw new Error("Agent error: " + ((data.error && data.error.message) || data.status));
    }
    return extractResponsesText(data);
  }

  // Extract assistant text from an OpenAI Responses payload.
  function extractResponsesText(data) {
    if (typeof data.output_text === "string" && data.output_text) return data.output_text;
    const texts = [];
    for (const item of (data.output || [])) {
      for (const c of (item.content || [])) {
        if (c && typeof c.text === "string") texts.push(c.text);
      }
    }
    return texts.join("\n") || "(no response)";
  }

  function appendMessage(container, kind, text) {
    const div = document.createElement("div");
    div.className = "msg " + kind;
    div.textContent = text;
    container.appendChild(div);
    container.scrollTop = container.scrollHeight;
    return div;
  }

  function escapeHtml(s) {
    return String(s).replace(/[&<>"']/g, c =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]));
  }

  init();
})();
