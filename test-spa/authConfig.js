/**
 * Configuration object to be passed to MSAL instance on creation. 
 * For a full list of MSAL.js configuration parameters, visit:
 * https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/configuration.md 
 */

const msalConfig = {
    auth: {
        clientId: '588795a9-eb8d-4221-a871-c8a5f990783a',
        authority: 'https://login.microsoftonline.com/06a05be1-33df-4feb-9009-95c7a27a7a49',
        redirectUri: 'http://localhost:5500/redirect.html',
        navigateToLoginRequestUrl: true, // If "true", will navigate back to the original request location before processing the auth code response.
    },
    cache: {
        cacheLocation: 'sessionStorage', // Configures cache location. "sessionStorage" is more secure, but "localStorage" gives you SSO.
        storeAuthStateInCookie: false, // set this to true if you have to support IE
    },
    system: {
        loggerOptions: {
            loggerCallback: (level, message, containsPii) => {
                if (containsPii) {
                    return;
                }
                switch (level) {
                    case msal.LogLevel.Error:
                        console.error(message);
                        return;
                    case msal.LogLevel.Info:
                        console.info(message);
                        return;
                    case msal.LogLevel.Verbose:
                        console.debug(message);
                        return;
                    case msal.LogLevel.Warning:
                        console.warn(message);
                        return;
                }
            },
        },
    },
};

/**
 * Scopes you add here will be prompted for user consent during sign-in.
 * By default, MSAL.js will add OIDC scopes (openid, profile, email) to any login request.
 * For more information about OIDC scopes, visit: 
 * https://docs.microsoft.com/en-us/azure/active-directory/develop/v2-permissions-and-consent#openid-connect-scopes
 */
const loginRequest = {
  scopes: ["openid", "profile", "api://defce565-2d94-4df1-94fe-3b411c3b0431/access_as_user"],
};

/**
 * An optional silentRequest object can be used to achieve silent SSO
 * between applications by providing a "login_hint" property.
 */

// const silentRequest = {
//   scopes: ["openid", "profile"],
//   loginHint: "example@domain.net"
// };

// Webhook endpoints for the n8n OBO workflow
const webhookUrl     = 'https://ca-n8n-isrgwn7mmqz46.delightfulforest-02601b4f.northeurope.azurecontainerapps.io/webhook/caef5339-caaa-4228-999d-89abf943bfe2';
const webhookTestUrl = 'https://ca-n8n-isrgwn7mmqz46.delightfulforest-02601b4f.northeurope.azurecontainerapps.io/webhook-test/caef5339-caaa-4228-999d-89abf943bfe2';

// exporting config object for jest
if (typeof exports !== 'undefined') {
  module.exports = {
      msalConfig: msalConfig,
      loginRequest: loginRequest,
  };
}