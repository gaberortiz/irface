/*
 * pam_irface — PAM auth shim for irface.
 *
 * Talks to the irface daemon (which owns the IR camera) over a Unix socket
 * and asks it to authenticate the target user. On success returns PAM_SUCCESS;
 * on ANY failure (daemon down, no match, timeout, malformed reply) returns
 * PAM_IGNORE so the rest of the auth stack (password) still runs — the system
 * can never be locked out by this module.
 *
 * Module options (in the PAM service files):
 *   socket=/run/irface/irface.sock   path to the daemon socket
 *   timeout=6                         seconds to wait for a reply
 *   debug                             log auth decisions to syslog
 */
#include <security/pam_modules.h>
#include <security/pam_appl.h>

#include <sys/socket.h>
#include <sys/un.h>
#include <syslog.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define IRFACE_DEFAULT_SOCKET "/run/irface/irface.sock"
#define IRFACE_DEFAULT_TIMEOUT 6
#define IRFACE_MAX_PATH 108 /* sizeof sockaddr_un.sun_path */

struct irface_opts {
    char socket_path[IRFACE_MAX_PATH];
    int timeout;
    int debug;
};

static void parse_args(int argc, const char **argv, struct irface_opts *o) {
    snprintf(o->socket_path, sizeof(o->socket_path), "%s", IRFACE_DEFAULT_SOCKET);
    o->timeout = IRFACE_DEFAULT_TIMEOUT;
    o->debug = 0;
    for (int i = 0; i < argc; i++) {
        if (strncmp(argv[i], "socket=", 7) == 0) {
            snprintf(o->socket_path, sizeof(o->socket_path), "%s", argv[i] + 7);
        } else if (strncmp(argv[i], "timeout=", 8) == 0) {
            o->timeout = atoi(argv[i] + 8);
            if (o->timeout <= 0) o->timeout = IRFACE_DEFAULT_TIMEOUT;
        } else if (strcmp(argv[i], "debug") == 0) {
            o->debug = 1;
        }
    }
}

static int ask_daemon(const struct irface_opts *o, const char *user, int *authed) {
    struct sockaddr_un addr;
    int fd, rv = -1;
    char req[512], resp[256];
    struct timeval tv;

    fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    /* Never block indefinitely: cap send/recv at the auth timeout + margin. */
    tv.tv_sec = o->timeout + 1;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));

    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    snprintf(addr.sun_path, sizeof(addr.sun_path), "%s", o->socket_path);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1; /* daemon not running -> password fallback */
    }

    snprintf(req, sizeof(req), "AUTH %s\n", user);
    if (write(fd, req, strlen(req)) < 0) {
        close(fd);
        return -1;
    }

    ssize_t n = read(fd, resp, sizeof(resp) - 1);
    close(fd);
    if (n <= 0) return -1;
    resp[n] = '\0';

    /* Response is "OK <reason> <sim>" or "NO <reason> <sim>". */
    if (strncmp(resp, "OK", 2) == 0) {
        *authed = 1;
        rv = 0;
    } else {
        *authed = 0;
        rv = 0;
    }
    if (o->debug) {
        /* trim trailing newline for clean logs */
        for (ssize_t i = n - 1; i >= 0; i--) {
            if (resp[i] == '\n' || resp[i] == '\r') resp[i] = '\0';
            else break;
        }
        syslog(LOG_INFO, "irface: user=%s reply=%s", user, resp);
    }
    return rv;
}

PAM_EXTERN int pam_sm_authenticate(pam_handle_t *pamh, int flags,
                                  int argc, const char **argv) {
    struct irface_opts o;
    const char *user = NULL;
    int authed = 0;

    (void)flags;
    parse_args(argc, argv, &o);

    if (pam_get_user(pamh, &user, NULL) != PAM_SUCCESS || user == NULL)
        return PAM_IGNORE;

    if (ask_daemon(&o, user, &authed) != 0)
        return PAM_IGNORE; /* can't reach daemon -> fallback to password */

    return authed ? PAM_SUCCESS : PAM_IGNORE;
}

PAM_EXTERN int pam_sm_setcred(pam_handle_t *pamh, int flags,
                              int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_acct_mgmt(pam_handle_t *pamh, int flags,
                                int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_open_session(pam_handle_t *pamh, int flags,
                                   int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_close_session(pam_handle_t *pamh, int flags,
                                    int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}

PAM_EXTERN int pam_sm_chauthtok(pam_handle_t *pamh, int flags,
                                int argc, const char **argv) {
    (void)pamh; (void)flags; (void)argc; (void)argv;
    return PAM_SUCCESS;
}
