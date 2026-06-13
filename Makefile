# Top-level Makefile: delegates to the three sub-makefiles.
# Usage: make [all|clean]

.PHONY: all clean

all:
	$(MAKE) -f Makefile.tests
	$(MAKE) -f Makefile.examples
	$(MAKE) -f Makefile.benchmarks

clean:
	$(MAKE) -f Makefile.tests clean
	$(MAKE) -f Makefile.examples clean
	$(MAKE) -f Makefile.benchmarks clean
