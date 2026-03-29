"use strict";

// ── State ────────────────────────────────────────────────────────────────────
let sessionId  = crypto.randomUUID();
let useTestUrl = false;

function getWebhookUrl() {
    return useTestUrl ? webhookTestUrl : webhookUrl;
}

// ── Auth UI callbacks (called by authPopup.js) ────────────────────────────
function onSignedIn(account) {
    document.getElementById('user-name').textContent   = account.name || account.username;
    document.getElementById('user-chip').style.display = 'flex';
    document.getElementById('auth-btn').textContent    = 'Sign out';
    document.getElementById('auth-btn').onclick        = signOut;
    document.getElementById('msg-input').disabled      = false;
    document.getElementById('send-btn').disabled       = false;
    document.getElementById('signin-placeholder')?.remove();
    updateSessionDisplay();
}

function onSignedOut() {
    document.getElementById('user-chip').style.display = 'none';
    document.getElementById('auth-btn').textContent    = 'Sign in';
    document.getElementById('auth-btn').onclick        = signIn;
    document.getElementById('msg-input').disabled      = true;
    document.getElementById('send-btn').disabled       = true;
}

// ── Token acquisition ────────────────────────────────────────────────────────
async function acquireToken() {
    const account = myMSALObj.getActiveAccount();
    if (!account) throw new Error('Not signed in');
    const request = { scopes: loginRequest.scopes, account };
    try {
        const result = await myMSALObj.acquireTokenSilent(request);
        return result.accessToken;
    } catch (e) {
        if (e instanceof msal.InteractionRequiredAuthError) {
            const result = await myMSALObj.acquireTokenPopup(request);
            return result.accessToken;
        }
        throw e;
    }
}

// ── Messaging ────────────────────────────────────────────────────────────────
async function sendMessage() {
    const input = document.getElementById('msg-input');
    const chatInput = input.value.trim();
    if (!chatInput) return;

    input.value = '';
    autoGrow(input);
    appendMessage('user', chatInput);

    input.disabled = true;
    document.getElementById('send-btn').disabled = true;

    const thinkingId = appendMessage('agent thinking', 'Thinking\u2026');

    let responseText = null;
    try {
        const token = await acquireToken();
        const resp  = await fetch(getWebhookUrl(), {
            method:  'POST',
            headers: {
                'Content-Type':  'application/json',
                'Authorization': 'Bearer ' + token
            },
            body: JSON.stringify({ chatInput, sessionId })
        });
        if (!resp.ok) {
            const body = await resp.text().catch(() => resp.statusText);
            throw new Error('HTTP ' + resp.status + ': ' + body);
        }
        responseText = await resp.text();
    } catch (e) {
        removeMessage(thinkingId);
        appendMessage('error', 'Error: ' + e.message);
    } finally {
        input.disabled = false;
        document.getElementById('send-btn').disabled = false;
        input.focus();
    }

    if (responseText !== null) {
        removeMessage(thinkingId);
        appendMessage('agent', responseText);
    }

    const wrap = document.getElementById('chat-wrap');
    wrap.scrollTop = wrap.scrollHeight;
}

// ── Session helpers ──────────────────────────────────────────────────────────
function newSession() {
    sessionId = crypto.randomUUID();
    updateSessionDisplay();
    const msgs = document.getElementById('messages');
    const sep  = document.createElement('div');
    sep.style.cssText = 'text-align:center;font-size:.7rem;color:#8b949e;padding:6px 0;border-top:1px solid #30363d;';
    sep.textContent   = '\u2014 new session \u2014';
    msgs.appendChild(sep);
    msgs.scrollTop = msgs.scrollHeight;
}

function updateSessionDisplay() {
    document.getElementById('session-id-display').textContent = sessionId.slice(0, 8) + '\u2026';
}

// ── UI helpers ───────────────────────────────────────────────────────────────
let msgCounter = 0;

function appendMessage(type, text) {
    const id         = 'msg-' + (++msgCounter);
    const isUser     = type === 'user';
    const isError    = type === 'error';
    const isThinking = type.includes('thinking');
    const msgClass   = isUser ? 'user' : isError ? 'agent error' : isThinking ? 'agent thinking' : 'agent';
    const label      = isUser ? '<i class="bi bi-person-fill"></i> You' : '<i class="bi bi-robot"></i> Agent';
    const ts         = new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    const div       = document.createElement('div');
    div.id          = id;
    div.className   = 'msg ' + msgClass;
    div.innerHTML   = '<div class="label">' + label + '</div>'
                    + '<div class="bubble">' + escapeHtml(text) + '</div>'
                    + '<div class="ts">' + ts + '</div>';

    document.getElementById('messages').appendChild(div);
    document.getElementById('chat-wrap').scrollTop = 999999;
    return id;
}

function removeMessage(id) {
    document.getElementById(id)?.remove();
}

function escapeHtml(text) {
    return text.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
               .replace(/"/g,'&quot;').replace(/'/g,'&#39;');
}

// ── Webhook mode toggle ───────────────────────────────────────────────────────
function toggleMode() {
    useTestUrl = !useTestUrl;
    const badge = document.getElementById('mode-badge');
    if (useTestUrl) {
        badge.className   = 'mode-badge test';
        badge.textContent = '\u26a0 TEST';
        badge.title = 'Using /webhook-test/ \u2014 workflow must be open in n8n. Click to switch to ACTIVE.';
    } else {
        badge.className   = 'mode-badge prod';
        badge.textContent = '\u25cf ACTIVE';
        badge.title = 'Using /webhook/ production path. Click to switch to TEST mode.';
    }
}

// ── Textarea auto-grow ────────────────────────────────────────────────────────
function autoGrow(el) {
    el.style.height = 'auto';
    el.style.height = Math.min(el.scrollHeight, 160) + 'px';
}

function handleKey(e) {
    if (e.key === 'Enter' && !e.shiftKey) {
        e.preventDefault();
        sendMessage();
    }
}

// ── Boot ──────────────────────────────────────────────────────────────────────
updateSessionDisplay();
