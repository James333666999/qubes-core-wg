/*
 * qvif - minimal Xen driver-domain hotplug helper for a Qubes netvm.
 *
 * What xl devd + vif-route-qubes normally do, reduced to the essentials:
 *   - watch backend/vif in xenstore (relative to our own domain);
 *   - for every vif backend that appears: run the "up" script
 *     (UP VIFNAME IP...), then write hotplug-status=connected, which is what
 *     lets xen-netback finish the xenbus state change;
 *   - when a backend goes away (or reaches Closing/Closed): run the "down"
 *     script (DOWN VIFNAME IP...).
 *
 * It speaks the xenstore wire protocol directly over /dev/xen/xenbus (or
 * /proc/xen/xenbus). "-s PATH" connects to a unix socket instead, which is
 * how it is tested against a fake xenstore.
 *
 * Build: gcc -O2 -static -Wall -o qvif qvif.c
 */
#define _GNU_SOURCE
#include <ctype.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>

enum {
	XS_DIRECTORY = 1,
	XS_READ = 2,
	XS_WATCH = 4,
	XS_WRITE = 11,
	XS_WATCH_EVENT = 15,
	XS_ERROR = 16
};

struct xsmsg {
	uint32_t type, req_id, tx_id, len;
};

#define MAXDEV 64
#define MAXMSG (64 * 1024)

struct dev {
	int used, dom, handle;
	int state; /* 0 = new, 1 = up, 2 = torn down (waiting for node to vanish) */
	int seen;
	char ips[256];
};

static int fd = -1;
static int verbose;
static int dirty;
static uint32_t next_id = 1;
static char xs_err[64];
static const char *up_script = "/usr/local/sbin/qvif-up";
static const char *down_script = "/usr/local/sbin/qvif-down";
static struct dev devs[MAXDEV];

static void logf_(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
static void logf_(const char *fmt, ...)
{
	va_list ap;
	if (!verbose)
		return;
	fputs("qvif: ", stderr);
	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fputc('\n', stderr);
}

static void die(const char *what)
{
	fprintf(stderr, "qvif: fatal: %s (%s)\n", what, strerror(errno));
	exit(1);
}

static int read_full(void *buf, size_t n)
{
	char *p = buf;
	while (n) {
		ssize_t r = read(fd, p, n);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		if (r == 0) {
			errno = ECONNRESET;
			return -1;
		}
		p += r;
		n -= (size_t)r;
	}
	return 0;
}

static int write_full(const void *buf, size_t n)
{
	const char *p = buf;
	while (n) {
		ssize_t r = write(fd, p, n);
		if (r < 0) {
			if (errno == EINTR)
				continue;
			return -1;
		}
		p += r;
		n -= (size_t)r;
	}
	return 0;
}

/* Read one message; *body is malloc'd, NUL-terminated (extra byte). */
static int read_msg(struct xsmsg *h, char **body)
{
	if (read_full(h, sizeof(*h)) < 0)
		return -1;
	if (h->len > MAXMSG) {
		errno = EMSGSIZE;
		return -1;
	}
	*body = malloc((size_t)h->len + 1);
	if (!*body)
		return -1;
	if (h->len && read_full(*body, h->len) < 0) {
		free(*body);
		return -1;
	}
	(*body)[h->len] = 0;
	return 0;
}

/* One request/response. Watch events seen meanwhile just set 'dirty'. */
static int xs_req(uint32_t type, const void *pl, uint32_t plen, char **out, uint32_t *outlen)
{
	uint32_t id = next_id++;
	struct xsmsg h = { type, id, 0, plen };
	size_t tot = sizeof(h) + plen;
	char *buf = malloc(tot);

	if (!buf)
		die("malloc");
	memcpy(buf, &h, sizeof(h));
	if (plen)
		memcpy(buf + sizeof(h), pl, plen);
	if (write_full(buf, tot) < 0)
		die("xenstore write");
	free(buf);

	for (;;) {
		struct xsmsg r;
		char *body;

		if (read_msg(&r, &body) < 0)
			die("xenstore read");
		if (r.type == XS_WATCH_EVENT) {
			dirty = 1;
			free(body);
			continue;
		}
		if (r.req_id != id) {
			free(body);
			continue;
		}
		if (r.type == XS_ERROR) {
			snprintf(xs_err, sizeof(xs_err), "%s", body);
			free(body);
			errno = EIO;
			return -1;
		}
		if (out) {
			*out = body;
			if (outlen)
				*outlen = r.len;
		} else {
			free(body);
		}
		return 0;
	}
}

static char *xs_read(const char *path)
{
	char *v;

	if (xs_req(XS_READ, path, (uint32_t)strlen(path) + 1, &v, NULL) < 0)
		return NULL;
	return v;
}

static int xs_write(const char *path, const char *val)
{
	size_t pl = strlen(path) + 1, vl = strlen(val);
	char *b = malloc(pl + vl);
	int r;

	if (!b)
		die("malloc");
	memcpy(b, path, pl);
	memcpy(b + pl, val, vl);
	r = xs_req(XS_WRITE, b, (uint32_t)(pl + vl), NULL, NULL);
	free(b);
	return r;
}

static int xs_watch(const char *path, const char *token)
{
	size_t pl = strlen(path) + 1, tl = strlen(token) + 1;
	char *b = malloc(pl + tl);
	int r;

	if (!b)
		die("malloc");
	memcpy(b, path, pl);
	memcpy(b + pl, token, tl);
	r = xs_req(XS_WATCH, b, (uint32_t)(pl + tl), NULL, NULL);
	free(b);
	return r;
}

static int all_digits(const char *s)
{
	if (!*s)
		return 0;
	for (; *s; s++)
		if (!isdigit((unsigned char)*s))
			return 0;
	return 1;
}

/* Keep only digits, dots, spaces: the value ends up in argv of a script. */
static void clean_ips(const char *in, char *out, size_t n)
{
	size_t j = 0;

	for (; *in && j + 1 < n; in++)
		if (isdigit((unsigned char)*in) || *in == '.' || *in == ' ')
			out[j++] = *in;
	out[j] = 0;
}

static int run_script(const char *script, const char *vif, const char *ips)
{
	char *argv[24];
	char tmp[256];
	int argc = 0, status;
	pid_t pid;
	char *save = NULL, *tok;

	snprintf(tmp, sizeof(tmp), "%s", ips);
	argv[argc++] = (char *)script;
	argv[argc++] = (char *)vif;
	for (tok = strtok_r(tmp, " ", &save); tok && argc < 22; tok = strtok_r(NULL, " ", &save))
		argv[argc++] = tok;
	argv[argc] = NULL;

	pid = fork();
	if (pid < 0)
		return -1;
	if (pid == 0) {
		execv(script, argv);
		fprintf(stderr, "qvif: exec %s: %s\n", script, strerror(errno));
		_exit(127);
	}
	while (waitpid(pid, &status, 0) < 0)
		if (errno != EINTR)
			return -1;
	return WIFEXITED(status) ? WEXITSTATUS(status) : -1;
}

static struct dev *find_dev(int dom, int handle, int create)
{
	int i, free_i = -1;

	for (i = 0; i < MAXDEV; i++) {
		if (devs[i].used && devs[i].dom == dom && devs[i].handle == handle)
			return &devs[i];
		if (!devs[i].used && free_i < 0)
			free_i = i;
	}
	if (!create || free_i < 0)
		return NULL;
	memset(&devs[free_i], 0, sizeof(devs[free_i]));
	devs[free_i].used = 1;
	devs[free_i].dom = dom;
	devs[free_i].handle = handle;
	return &devs[free_i];
}

static void dev_up(struct dev *d, const char *path)
{
	char vif[48], p[160], *ipv, hp[176];
	int rc;

	snprintf(vif, sizeof(vif), "vif%d.%d", d->dom, d->handle);
	snprintf(p, sizeof(p), "%s/ip", path);
	ipv = xs_read(p);
	clean_ips(ipv ? ipv : "", d->ips, sizeof(d->ips));
	free(ipv);

	logf_("up %s ip='%s'", vif, d->ips);
	rc = run_script(up_script, vif, d->ips);
	snprintf(hp, sizeof(hp), "%s/hotplug-status", path);
	if (rc == 0) {
		xs_write(hp, "connected");
		logf_("%s connected", vif);
	} else {
		char ep[176];

		fprintf(stderr, "qvif: %s failed (rc=%d)\n", up_script, rc);
		xs_write(hp, "error");
		snprintf(ep, sizeof(ep), "%s/hotplug-error", path);
		xs_write(ep, "qvif-up failed");
	}
	d->state = 1;
}

static void dev_down(struct dev *d)
{
	char vif[48];

	snprintf(vif, sizeof(vif), "vif%d.%d", d->dom, d->handle);
	logf_("down %s", vif);
	run_script(down_script, vif, d->ips);
	d->state = 2;
}

static void scan(void)
{
	char *dl, *hl, *p, *q;
	uint32_t dll, hll;
	int i;

	for (i = 0; i < MAXDEV; i++)
		devs[i].seen = 0;

	if (xs_req(XS_DIRECTORY, "backend/vif", 12, &dl, &dll) == 0) {
		for (p = dl; p < dl + dll; p += strlen(p) + 1) {
			char dp[64];

			if (!all_digits(p))
				continue;
			snprintf(dp, sizeof(dp), "backend/vif/%s", p);
			if (xs_req(XS_DIRECTORY, dp, (uint32_t)strlen(dp) + 1, &hl, &hll) < 0)
				continue;
			for (q = hl; q < hl + hll; q += strlen(q) + 1) {
				char path[96], sp[112], *st;
				struct dev *d;
				int stn;

				if (!all_digits(q))
					continue;
				snprintf(path, sizeof(path), "%s/%s", dp, q);
				snprintf(sp, sizeof(sp), "%s/state", path);
				st = xs_read(sp);
				if (!st)
					continue; /* still being created */
				stn = atoi(st);
				free(st);
				d = find_dev(atoi(p), atoi(q), 1);
				if (!d)
					continue;
				d->seen = 1;
				if (stn >= 5) { /* Closing / Closed */
					if (d->state == 1)
						dev_down(d);
					continue;
				}
				if (d->state == 0)
					dev_up(d, path);
			}
			free(hl);
		}
		free(dl);
	}

	for (i = 0; i < MAXDEV; i++) {
		if (!devs[i].used || devs[i].seen)
			continue;
		if (devs[i].state == 1)
			dev_down(&devs[i]);
		devs[i].used = 0;
	}
}

static int open_store(const char *sock, const char *dev)
{
	if (sock) {
		struct sockaddr_un a;
		int s = socket(AF_UNIX, SOCK_STREAM, 0);

		if (s < 0)
			return -1;
		memset(&a, 0, sizeof(a));
		a.sun_family = AF_UNIX;
		snprintf(a.sun_path, sizeof(a.sun_path), "%s", sock);
		if (connect(s, (struct sockaddr *)&a, sizeof(a)) < 0)
			return -1;
		return s;
	}
	if (dev)
		return open(dev, O_RDWR);
	{
		int f = open("/dev/xen/xenbus", O_RDWR);

		if (f < 0)
			f = open("/proc/xen/xenbus", O_RDWR);
		return f;
	}
}

int main(int argc, char **argv)
{
	const char *sock = NULL, *dev = NULL;
	int c;

	while ((c = getopt(argc, argv, "s:d:u:D:v")) != -1) {
		switch (c) {
		case 's': sock = optarg; break;
		case 'd': dev = optarg; break;
		case 'u': up_script = optarg; break;
		case 'D': down_script = optarg; break;
		case 'v': verbose = 1; break;
		default:
			fprintf(stderr, "usage: qvif [-v] [-s socket|-d device] [-u up] [-D down]\n");
			return 2;
		}
	}
	signal(SIGPIPE, SIG_IGN);
	setvbuf(stderr, NULL, _IOLBF, 0);

	fd = open_store(sock, dev);
	if (fd < 0)
		die("cannot open xenstore (/dev/xen/xenbus, /proc/xen/xenbus)");

	if (xs_watch("backend/vif", "qvif") < 0) {
		errno = EIO;
		fprintf(stderr, "qvif: xs_watch failed: %s\n", xs_err);
		return 1;
	}
	logf_("watching backend/vif");
	scan();
	for (;;) {
		struct xsmsg h;
		char *b;

		if (read_msg(&h, &b) < 0)
			die("xenstore read");
		if (h.type == XS_WATCH_EVENT)
			dirty = 1;
		free(b);
		if (dirty) {
			dirty = 0;
			scan();
		}
	}
}
