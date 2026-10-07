# rootshim.so: the LD_PRELOAD helper sandbox.sh uses for --root (see rootshim.c)

CC      ?= cc
CFLAGS  ?= -O2 -Wall -Wextra
LDFLAGS ?=

all: rootshim.so

rootshim.so: rootshim.c
	$(CC) $(CFLAGS) -shared -fPIC -o $@ $< $(LDFLAGS)

clean:
	rm -f rootshim.so

.PHONY: all clean
