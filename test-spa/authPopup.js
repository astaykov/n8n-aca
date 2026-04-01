// Create the main myMSALObj instance
// configuration parameters are located at authConfig.js
const myMSALObj = new msal.PublicClientApplication(msalConfig);

let username = "";

function selectAccount () {
    const currentAccounts = myMSALObj.getAllAccounts();
    if (!currentAccounts || currentAccounts.length < 1) {
        return;
    }
    const account = currentAccounts[0];
    username = account.username;
    myMSALObj.setActiveAccount(account);
    onSignedIn(account);
}

function handleResponse(response) {
    if (response !== null) {
        username = response.account.username;
        myMSALObj.setActiveAccount(response.account);
        onSignedIn(response.account);
    } else {
        selectAccount();
    }
}

function signIn() {

    /**
     * You can pass a custom request object below. This will override the initial configuration. For more information, visit:
     * https://github.com/AzureAD/microsoft-authentication-library-for-js/blob/dev/lib/msal-browser/docs/request-response-object.md#request
     */

    myMSALObj.loginPopup(loginRequest)
        .then(handleResponse)
        .catch(error => {
            if (error.errorCode !== 'user_cancelled') {
                console.error(error);
                appendMessage('error', 'Sign-in failed: ' + (error.message || error.errorCode));
            }
        });
}

function signOut() {
    const logoutRequest = {
        account: myMSALObj.getAccountByUsername(username),
        mainWindowRedirectUri: window.location.href,
        redirectUri: window.location.origin + '/redirect.html',
    };
    myMSALObj.logoutPopup(logoutRequest).then(onSignedOut);
}

selectAccount();
