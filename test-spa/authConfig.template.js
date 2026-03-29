/**
 * authConfig.template.js — used by the Docker container (nginx + entrypoint.sh).
 * Placeholders are replaced at container startup via sed in entrypoint.sh.
 * For local development, use authConfig.js (hardcoded values).
 *
 * Placeholders:
 *   __SPA_CLIENT_ID__        — App Registration clientId for the SPA
 *   __SPA_TENANT_ID__        — Entra tenant ID
 *   __SPA_REDIRECT_URI__     — Full redirect URI, e.g. https://<fqdn>/redirect.html
 *   __SPA_BLUEPRINT_APP_ID__ — Blueprint app ID (OAuth2 appId, not object ID)
 *   __N8N_WEBHOOK_URL__      — Full n8n production webhook URL
 *   __N8N_WEBHOOK_TEST_URL__ — Full n8n test webhook URL
 */

const msalConfig = {
    auth: {
        clientId: '__SPA_CLIENT_ID__',
        authority: 'https://login.microsoftonline.com/__SPA_TENANT_ID__',
        redirectUri: '__SPA_REDIRECT_URI__',
        navigateToLoginRequestUrl: true,
    },
    cache: {
        cacheLocation: 'sessionStorage',
        storeAuthStateInCookie: false,
    },
    system: {
        loggerOptions: {
            loggerCallback: (level, message, containsPii) => {
                if (containsPii) { return; }
                switch (level) {
                    case msal.LogLevel.Error:   console.error(message);  return;
                    case msal.LogLevel.Info:    console.info(message);   return;
                    case msal.LogLevel.Verbose: console.debug(message);  return;
                    case msal.LogLevel.Warning: console.warn(message);   return;
                }
            },
        },
    },
};

const loginRequest = {
    scopes: ["openid", "profile", "api://__SPA_BLUEPRINT_APP_ID__/access_as_user"],
};

// Webhook endpoints for the n8n OBO workflow
const webhookUrl     = '__N8N_WEBHOOK_URL__';
const webhookTestUrl = '__N8N_WEBHOOK_TEST_URL__';

// exporting config object for jest
if (typeof exports !== 'undefined') {
    module.exports = { msalConfig, loginRequest };
}
