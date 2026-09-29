CC ?= gcc
CFLAGS ?= -O2 -Wall -Wextra -fPIC

all: pam_irface.so pam_passcheck

pam_irface.so: pam_irface.c
	$(CC) $(CFLAGS) -shared -o $@ $< -lpam

pam_passcheck: pam_passcheck.c
	$(CC) $(CFLAGS) -o $@ $< -lpam

install: all
	install -Dm755 pam_irface.so $(DESTDIR)/usr/lib/security/pam_irface.so
	install -Dm755 pam_passcheck  $(DESTDIR)/usr/lib/security/pam_passcheck

clean:
	rm -f pam_irface.so pam_passcheck

.PHONY: all install clean
