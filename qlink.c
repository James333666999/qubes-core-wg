/*
 * qlink - create a network interface of a given kind over rtnetlink.
 *
 * Tiny Core's busybox has no 'ip link add ... type wireguard'. This does just
 * that one thing:   qlink add NAME KIND [MTU]
 * e.g.              qlink add wg0 wireguard 1420
 *
 * Build: gcc -O2 -static -Wall -o qlink qlink.c
 */
#include <errno.h>
#include <linux/if_link.h>
#include <linux/netlink.h>
#include <linux/rtnetlink.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static struct rtattr *put_attr(struct nlmsghdr *n, size_t max, int type, const void *data, size_t len)
{
	struct rtattr *rta = (struct rtattr *)((char *)n + NLMSG_ALIGN(n->nlmsg_len));

	if (NLMSG_ALIGN(n->nlmsg_len) + RTA_SPACE(len) > max) {
		fprintf(stderr, "qlink: message too large\n");
		exit(1);
	}
	rta->rta_type = (unsigned short)type;
	rta->rta_len = (unsigned short)RTA_LENGTH(len);
	if (len)
		memcpy(RTA_DATA(rta), data, len);
	n->nlmsg_len = NLMSG_ALIGN(n->nlmsg_len) + RTA_ALIGN(rta->rta_len);
	return rta;
}

int main(int argc, char **argv)
{
	struct {
		struct nlmsghdr n;
		struct ifinfomsg i;
		char buf[512];
	} req;
	struct rtattr *linkinfo;
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	char rbuf[1024];
	struct nlmsghdr *h;
	ssize_t r;
	int s;

	if (argc < 4 || strcmp(argv[1], "add") != 0 || strlen(argv[2]) >= 16) {
		fprintf(stderr, "usage: qlink add NAME KIND [MTU]\n");
		return 2;
	}
	memset(&req, 0, sizeof(req));
	req.n.nlmsg_len = NLMSG_LENGTH(sizeof(struct ifinfomsg));
	req.n.nlmsg_type = RTM_NEWLINK;
	req.n.nlmsg_flags = NLM_F_REQUEST | NLM_F_CREATE | NLM_F_EXCL | NLM_F_ACK;
	req.n.nlmsg_seq = 1;
	req.i.ifi_family = AF_UNSPEC;

	put_attr(&req.n, sizeof(req), IFLA_IFNAME, argv[2], strlen(argv[2]) + 1);
	if (argc > 4) {
		unsigned int mtu = (unsigned int)atoi(argv[4]);

		put_attr(&req.n, sizeof(req), IFLA_MTU, &mtu, sizeof(mtu));
	}
	linkinfo = put_attr(&req.n, sizeof(req), IFLA_LINKINFO | NLA_F_NESTED, NULL, 0);
	put_attr(&req.n, sizeof(req), IFLA_INFO_KIND, argv[3], strlen(argv[3]) + 1);
	linkinfo->rta_len = (unsigned short)((char *)&req + NLMSG_ALIGN(req.n.nlmsg_len) - (char *)linkinfo);

	s = socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, NETLINK_ROUTE);
	if (s < 0) {
		perror("qlink: socket");
		return 1;
	}
	if (sendto(s, &req, req.n.nlmsg_len, 0, (struct sockaddr *)&sa, sizeof(sa)) < 0) {
		perror("qlink: send");
		return 1;
	}
	r = recv(s, rbuf, sizeof(rbuf), 0);
	if (r < 0) {
		perror("qlink: recv");
		return 1;
	}
	for (h = (struct nlmsghdr *)rbuf; NLMSG_OK(h, (unsigned)r); h = NLMSG_NEXT(h, r)) {
		if (h->nlmsg_type == NLMSG_ERROR) {
			struct nlmsgerr *e = NLMSG_DATA(h);

			if (e->error == 0)
				return 0;
			fprintf(stderr, "qlink: add %s (%s): %s\n", argv[2], argv[3], strerror(-e->error));
			return 1;
		}
	}
	fprintf(stderr, "qlink: no reply\n");
	return 1;
}
