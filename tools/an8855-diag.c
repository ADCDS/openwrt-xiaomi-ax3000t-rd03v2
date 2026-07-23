// SPDX-License-Identifier: GPL-2.0
/*
 * an8855-diag — userspace diagnostic client for the an8855_dsa genetlink
 * interface (an8855_nl.c). Raw switch register read/write plus decoded
 * FDB-table and VLAN-table dumps, for debugging the tag_8021q bridge
 * delivery path on the RD03v2 port (ADCDS/openwrt-xiaomi-ax3000t-rd03v2).
 *
 * Build (static, OpenWrt aarch64 musl toolchain):
 *   aarch64-openwrt-linux-musl-gcc -static -O2 -o an8855-diag an8855-diag.c
 *
 * Usage:
 *   an8855-diag read <hex-reg>
 *   an8855-diag write <hex-reg> <hex-val>
 *   an8855-diag fdb            # dump all live FDB entries (MAC, VID, ports)
 *   an8855-diag vlan <vid>...  # dump VLAN table entries
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <stdint.h>
#include <sys/socket.h>
#include <linux/netlink.h>
#include <linux/genetlink.h>

#define AN8855_GENL_NAME "an8855_dsa"
#define AN8855_GENL_VERSION 0x1

enum { AN8855_CMD_UNSPEC, AN8855_CMD_REQUEST, AN8855_CMD_REPLY,
       AN8855_CMD_READ, AN8855_CMD_WRITE };
enum { AN8855_ATTR_UNSPEC, AN8855_ATTR_MESG, AN8855_ATTR_PHY,
       AN8855_ATTR_DEVAD, AN8855_ATTR_REG, AN8855_ATTR_VAL };

/* Switch registers (an8855.h) */
#define REG_ATC		0x10200300
#define   ATC_BUSY	(1u << 31)
#define   ATC_HIT_SHIFT	12
#define   ATC_HIT_MASK	0xFu
#define   ATC_MAT_SHIFT	7
#define   MAT_MAC	1	/* all MAC entries */
#define   FDB_START	4
#define   FDB_NEXT	5
#define REG_ATWD2	0x10200328
#define REG_ATRDS	0x10200330
#define REG_ATRD0	0x10200334
#define REG_ATRD1	0x10200338
#define REG_ATRD2	0x1020033c
#define REG_ATRD3	0x10200340
#define REG_VTCR	0x10200600
#define   VTCR_BUSY	(1u << 31)
#define   VTCR_RD_VID	0
#define REG_VARD0	0x10200618

#define NLA_HDRLEN_A	((int)NLA_ALIGN(sizeof(struct nlattr)))

static int nlsock = -1;
static uint16_t family_id;
static uint32_t nl_seq = 1;

static void die(const char *msg)
{
	perror(msg);
	exit(1);
}

struct nlmsg {
	struct nlmsghdr n;
	struct genlmsghdr g;
	char buf[512];
};

static void nla_put(struct nlmsg *m, uint16_t type, const void *data, int len)
{
	struct nlattr *a = (struct nlattr *)((char *)&m->n + NLMSG_ALIGN(m->n.nlmsg_len));

	a->nla_type = type;
	a->nla_len = NLA_HDRLEN_A + len;
	memcpy((char *)a + NLA_HDRLEN_A, data, len);
	m->n.nlmsg_len = NLMSG_ALIGN(m->n.nlmsg_len) + NLA_ALIGN(a->nla_len);
}

static void nla_put_u32(struct nlmsg *m, uint16_t type, uint32_t val)
{
	nla_put(m, type, &val, sizeof(val));
}

static int nl_txrx(struct nlmsg *m, char *rxbuf, int rxlen)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };
	int len;

	m->n.nlmsg_seq = nl_seq++;
	m->n.nlmsg_pid = getpid();
	if (sendto(nlsock, m, m->n.nlmsg_len, 0,
		   (struct sockaddr *)&sa, sizeof(sa)) < 0)
		die("sendto");

	len = recv(nlsock, rxbuf, rxlen, 0);
	if (len < 0)
		die("recv");
	return len;
}

/* Walk attrs of a genlmsg reply; return pointer to attr of given type. */
static struct nlattr *find_attr(struct nlmsghdr *n, uint16_t type)
{
	int len = n->nlmsg_len - NLMSG_LENGTH(GENL_HDRLEN);
	struct nlattr *a = (struct nlattr *)((char *)NLMSG_DATA(n) + GENL_HDRLEN);

	while (len >= NLA_HDRLEN_A) {
		if ((a->nla_type & NLA_TYPE_MASK) == type)
			return a;
		len -= NLA_ALIGN(a->nla_len);
		a = (struct nlattr *)((char *)a + NLA_ALIGN(a->nla_len));
	}
	return NULL;
}

static void genl_resolve(void)
{
	struct nlmsg m = { };
	char rxbuf[1024];
	struct nlmsghdr *rn;
	struct nlattr *a;

	m.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	m.n.nlmsg_type = GENL_ID_CTRL;
	m.n.nlmsg_flags = NLM_F_REQUEST;
	m.g.cmd = CTRL_CMD_GETFAMILY;
	m.g.version = 1;
	nla_put(&m, CTRL_ATTR_FAMILY_NAME, AN8855_GENL_NAME,
		strlen(AN8855_GENL_NAME) + 1);

	nl_txrx(&m, rxbuf, sizeof(rxbuf));
	rn = (struct nlmsghdr *)rxbuf;
	if (rn->nlmsg_type == NLMSG_ERROR) {
		fprintf(stderr, "genl family '%s' not found\n", AN8855_GENL_NAME);
		exit(1);
	}
	a = find_attr(rn, CTRL_ATTR_FAMILY_ID);
	if (!a) {
		fprintf(stderr, "no family id in reply\n");
		exit(1);
	}
	family_id = *(uint16_t *)((char *)a + NLA_HDRLEN_A);
}

static uint32_t reg_read(uint32_t reg)
{
	struct nlmsg m = { };
	char rxbuf[1024];
	struct nlmsghdr *rn;
	struct nlattr *a;

	m.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	m.n.nlmsg_type = family_id;
	m.n.nlmsg_flags = NLM_F_REQUEST;
	m.g.cmd = AN8855_CMD_READ;
	m.g.version = AN8855_GENL_VERSION;
	nla_put_u32(&m, AN8855_ATTR_REG, reg);

	nl_txrx(&m, rxbuf, sizeof(rxbuf));
	rn = (struct nlmsghdr *)rxbuf;
	if (rn->nlmsg_type == NLMSG_ERROR) {
		struct nlmsgerr *e = NLMSG_DATA(rn);
		fprintf(stderr, "read 0x%08x: nlerr %d\n", reg, e->error);
		exit(1);
	}
	a = find_attr(rn, AN8855_ATTR_VAL);
	if (!a) {
		fprintf(stderr, "read 0x%08x: no VAL attr\n", reg);
		exit(1);
	}
	return *(uint32_t *)((char *)a + NLA_HDRLEN_A);
}

static void reg_write(uint32_t reg, uint32_t val)
{
	struct nlmsg m = { };
	char rxbuf[1024];
	struct nlmsghdr *rn;

	m.n.nlmsg_len = NLMSG_LENGTH(GENL_HDRLEN);
	m.n.nlmsg_type = family_id;
	m.n.nlmsg_flags = NLM_F_REQUEST;
	m.g.cmd = AN8855_CMD_WRITE;
	m.g.version = AN8855_GENL_VERSION;
	nla_put_u32(&m, AN8855_ATTR_REG, reg);
	nla_put_u32(&m, AN8855_ATTR_VAL, val);

	nl_txrx(&m, rxbuf, sizeof(rxbuf));
	rn = (struct nlmsghdr *)rxbuf;
	if (rn->nlmsg_type == NLMSG_ERROR) {
		struct nlmsgerr *e = NLMSG_DATA(rn);
		if (e->error) {
			fprintf(stderr, "write 0x%08x: nlerr %d\n", reg, e->error);
			exit(1);
		}
	}
}

static int atc_wait(uint32_t *out)
{
	uint32_t v;
	int i;

	for (i = 0; i < 200; i++) {
		v = reg_read(REG_ATC);
		if (!(v & ATC_BUSY)) {
			*out = v;
			return 0;
		}
		usleep(1000);
	}
	return -1;
}

static void fdb_dump(void)
{
	uint32_t rsp, r0, r1, r2, r3;
	int count = 0, printed = 0;

	/* search: all MAC entries */
	reg_write(REG_ATWD2, 0xFF);	/* all ports */
	reg_write(REG_ATC, ATC_BUSY | (MAT_MAC << ATC_MAT_SHIFT) | FDB_START);
	if (atc_wait(&rsp)) {
		fprintf(stderr, "ATC busy timeout\n");
		exit(1);
	}

	printf("%-17s %5s %4s %4s %-9s %6s %5s\n",
	       "MAC", "VID", "FID", "IVL", "ports", "aging", "type");
	while (1) {
		int banks = (rsp >> ATC_HIT_SHIFT) & ATC_HIT_MASK;
		int i;

		if (!banks)
			break;
		for (i = 0; i < 4; i++) {
			count++;
			if (!(banks & (1 << i)))
				continue;
			reg_write(REG_ATRDS, i);
			usleep(2000);
			r0 = reg_read(REG_ATRD0);
			r1 = reg_read(REG_ATRD1);
			r2 = reg_read(REG_ATRD2);
			r3 = reg_read(REG_ATRD3);
			if (!(r0 & 1))	/* live */
				continue;
			printf("%02x:%02x:%02x:%02x:%02x:%02x %5u %4u %4u 0x%02x      %6u %5u\n",
			       (r2 >> 24) & 0xff, (r2 >> 16) & 0xff,
			       (r2 >> 8) & 0xff, r2 & 0xff,
			       (r1 >> 24) & 0xff, (r1 >> 16) & 0xff,
			       (r0 >> 10) & 0xfff,	/* vid */
			       (r0 >> 25) & 0xf,	/* fid */
			       (r0 >> 9) & 1,		/* ivl */
			       r3 & 0xff,		/* port mask */
			       (r1 >> 3) & 0x1ff,	/* aging */
			       (r0 >> 3) & 3);		/* type */
			printed++;
		}
		if (count >= 2048)
			break;
		reg_write(REG_ATC, ATC_BUSY | (MAT_MAC << ATC_MAT_SHIFT) | FDB_NEXT);
		if (atc_wait(&rsp)) {
			fprintf(stderr, "ATC busy timeout (next)\n");
			break;
		}
	}
	printf("-- %d live entries --\n", printed);
}

static void vlan_dump(uint16_t vid)
{
	uint32_t v, vard0;
	int i;

	reg_write(REG_VTCR, VTCR_BUSY | (VTCR_RD_VID << 12) | vid);
	for (i = 0; i < 200; i++) {
		v = reg_read(REG_VTCR);
		if (!(v & VTCR_BUSY))
			break;
		usleep(1000);
	}
	vard0 = reg_read(REG_VARD0);
	printf("VID%u: VARD0=%08x valid=%u vtag_en=%u eg_con=%u ivl=%u fid=%u members=0x%02x etag=0x%03x\n",
	       vid, vard0,
	       vard0 & 1,			/* VA0_VLAN_VALID  bit 0 */
	       (vard0 >> 10) & 1,		/* VA0_VTAG_EN     bit 10 */
	       (vard0 >> 11) & 1,		/* VA0_EG_CON      bit 11 */
	       (vard0 >> 5) & 1,		/* VA0_IVL_MAC     bit 5 */
	       (vard0 >> 1) & 0xf,		/* VA0_FID         bits 4:1 */
	       (vard0 >> 26) & 0x3f,		/* VA0_PORT        bits 31:26 */
	       (vard0 >> 12) & 0xfff);		/* VA0_ETAG        bits 23:12 */
}

int main(int argc, char **argv)
{
	struct sockaddr_nl sa = { .nl_family = AF_NETLINK };

	if (argc < 2) {
		fprintf(stderr,
			"usage: %s read <hexreg> | write <hexreg> <hexval> | fdb | vlan <vid>...\n",
			argv[0]);
		return 1;
	}

	nlsock = socket(AF_NETLINK, SOCK_RAW, NETLINK_GENERIC);
	if (nlsock < 0)
		die("socket");
	if (bind(nlsock, (struct sockaddr *)&sa, sizeof(sa)) < 0)
		die("bind");
	genl_resolve();

	if (!strcmp(argv[1], "read") && argc == 3) {
		uint32_t reg = strtoul(argv[2], NULL, 16);
		printf("0x%08x = 0x%08x\n", reg, reg_read(reg));
	} else if (!strcmp(argv[1], "write") && argc == 4) {
		uint32_t reg = strtoul(argv[2], NULL, 16);
		uint32_t val = strtoul(argv[3], NULL, 16);
		reg_write(reg, val);
		printf("0x%08x <= 0x%08x\n", reg, val);
	} else if (!strcmp(argv[1], "fdb")) {
		fdb_dump();
	} else if (!strcmp(argv[1], "vlan")) {
		int i;
		for (i = 2; i < argc; i++)
			vlan_dump(strtoul(argv[i], NULL, 0));
	} else {
		fprintf(stderr, "bad args\n");
		return 1;
	}
	return 0;
}
