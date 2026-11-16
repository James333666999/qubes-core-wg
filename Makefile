# Builds the two small static helpers that go into the gateway image.
#   make          -> ./qvif ./qlink
#   make test     -> unit/flow tests (needs root, nft, unshare, python3)
#   make clean
# Static linking matters: Tiny Core's userland has no glibc of its own to rely on.
CC     ?= cc
CFLAGS ?= -O2 -Wall -Wextra

all: qvif qlink

qvif: qvif.c
	$(CC) $(CFLAGS) -static -o $@ $<

qlink: qlink.c
	$(CC) $(CFLAGS) -static -o $@ $<

test: all
	sh tests/run.sh

clean:
	rm -f qvif qlink ov2.gz initramfs.gz

.PHONY: all test clean
