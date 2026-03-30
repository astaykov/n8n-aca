"use strict";

// ── Conversation state ────────────────────────────────────────────────────────
// conversations: id → { id, sessionId, title, updatedAt, messages:[{type,text,ts}] }
const conversations = {};
let activeConvId    = null;
let sessionId       = null;   // kept in sync with the active conversation

function getWebhookUrl() { return webhookUrl; }

// ── Auth UI callbacks (called by authPopup.js) ────────────────────────────────
function onSignedIn(account) {
    document.getElementById('user-name').textContent   = account.name || account.username;
    document.getElementById('user-chip').style.display = 'flex';
    document.getElementById('auth-btn').textContent    = 'Sign out';
    document.getElementById('auth-btn').onclick        = signOut;
    document.getElementById('msg-input').disabled      = false;
    document.getElementById('send-btn').disabled       = false;
    document.getElementById('signin-placeholder')?.remove();
}

function onSignedOut() {
    document.getElementById('user-chip').style.display = 'none';
    document.getElementById('auth-btn').textContent    = 'Sign in';
    document.getElementById('auth-btn').onclick        = signIn;
    document.getElementById('msg-input').disabled      = true;
    document.getElementById('send-btn').disabled       = true;
}

// ── Token acquisition ─────────────────────────────────────────────────────────
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

// ── Messaging ─────────────────────────────────────────────────────────────────
async function sendMessage() {
    const input     = document.getElementById('msg-input');
    const chatInput = input.value.trim();
    if (!chatInput) return;

    input.value = '';
    autoGrow(input);

    // Ensure there is an active conversation
    if (!activeConvId) newConversation();
    const conv = conversations[activeConvId];

    // Use first user message as thread title
    if (conv.title === 'New conversation') {
        conv.title = chatInput.slice(0, 45) + (chatInput.length > 45 ? '\u2026' : '');
        renderSidebar();
    }

    appendMessage('user', chatInput);

    input.disabled = true;
    document.getElementById('send-btn').disabled = true;
    const thinkingId = appendMessage('agent thinking', 'Thinking\u2026');

    let responseText = null;
    try {
        const token = await acquireToken();
        const resp  = await fetch(getWebhookUrl(), {
            method:  'POST',
            headers: { 'Content-Type': 'application/json', 'Authorization': 'Bearer ' + token },
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

    document.getElementById('chat-wrap').scrollTop = 999999;
}

// ── Conversation management ───────────────────────────────────────────────────
function newConversation() {
    const id  = crypto.randomUUID();
    const sid = crypto.randomUUID();
    conversations[id] = { id, sessionId: sid, title: 'New conversation', updatedAt: Date.now(), messages: [] };
    activeConvId = id;
    sessionId    = sid;
    document.getElementById('messages').innerHTML = '';
    renderSidebar();
}

function switchToConversation(id) {
    if (id === activeConvId) return;
    activeConvId = id;
    const conv   = conversations[id];
    sessionId    = conv.sessionId;
    document.getElementById('messages').innerHTML = '';
    msgCounter = 0;
    conv.messages.forEach(m => appendMessage(m.type, m.text, false, m.ts));
    renderSidebar();
    document.getElementById('chat-wrap').scrollTop = 999999;
}

function renderSidebar() {
    const list   = document.getElementById('thread-list');
    const sorted = Object.values(conversations).sort((a, b) => b.updatedAt - a.updatedAt);
    list.innerHTML = sorted.map(c =>
        `<div class="thread-item${c.id === activeConvId ? ' active' : ''}" onclick="switchToConversation('${c.id}')">`
        + `<i class="bi bi-chat-left-text"></i>`
        + `<span class="thread-title">${escapeHtml(c.title)}</span>`
        + `</div>`
    ).join('');
}

// ── UI helpers ────────────────────────────────────────────────────────────────
let msgCounter = 0;

function appendMessage(type, text, save = true, storedTs = null) {
    const id         = 'msg-' + (++msgCounter);
    const isUser     = type === 'user';
    const isError    = type === 'error';
    const isThinking = type.includes('thinking');
    const msgClass   = isUser ? 'user' : isError ? 'agent error' : isThinking ? 'agent thinking' : 'agent';
    const label      = isUser ? '<i class="bi bi-person-fill"></i> You' : '<i class="bi bi-robot"></i> Agent';
    const ts         = storedTs || new Date().toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });

    const renderBody = (isUser || isError || isThinking)
        ? escapeHtml(text)
        : DOMPurify.sanitize(marked.parse(text));

    const div     = document.createElement('div');
    div.id        = id;
    div.className = 'msg ' + msgClass;
    div.innerHTML = '<div class="label">' + label + '</div>'
                  + '<div class="bubble">' + renderBody + '</div>'
                  + '<div class="ts">' + ts + '</div>';

    document.getElementById('messages').appendChild(div);
    document.getElementById('chat-wrap').scrollTop = 999999;

    // Persist to conversation state (skip ephemeral thinking bubbles)
    if (save && !isThinking && activeConvId) {
        const conv = conversations[activeConvId];
        conv.messages.push({ type, text, ts });
        conv.updatedAt = Date.now();
        renderSidebar();
    }

    return id;
}

function removeMessage(id) {
    document.getElementById(id)?.remove();
}

function escapeHtml(text) {
    return String(text)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
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
newConversation();
