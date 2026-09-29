/*
 * pam_passcheck — verify a password via PAM (for the irface lock screen
 * fallback). Reads the password from stdin (first line) and the username
 * from argv[1]. Authenticates against the "irface-lock" PAM service, which
 * includes system-auth (pam_unix) only — NOT the face module — so there is
 * no recursion. Exits 0 on success, 1 on failure.
 */
#include <security/pam_appl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const char *g_pw = NULL;

static int conv_fn(int n, const struct pam_message **msg,
                   struct pam_response **resp, void *appdata) {
    (void)msg; (void)appdata;
    struct pam_response *r = calloc(n, sizeof(*r));
    if (!r) return PAM_CONV_ERR;
    for (int i = 0; i < n; i++) {
        r[i].resp = strdup(g_pw ? g_pw : "");
        r[i].resp_retcode = 0;
    }
    *resp = r;
    return PAM_SUCCESS;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <username>  (password on stdin)\n", argv[0]);
        return 2;
    }
    static char line[4096];
    if (!fgets(line, sizeof(line), stdin)) return 1;
    line[strcspn(line, "\r\n")] = '\0';
    g_pw = line;

    struct pam_conv conv = { conv_fn, NULL };
    pam_handle_t *pamh = NULL;
    const char *service = "irface-lock";

    if (pam_start(service, argv[1], &conv, &pamh) != PAM_SUCCESS) return 1;
    int rc = pam_authenticate(pamh, 0);
    pam_end(pamh, rc);
    return rc == PAM_SUCCESS ? 0 : 1;
}
