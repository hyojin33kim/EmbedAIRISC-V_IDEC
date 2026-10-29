#------------------------------------------------------------------
# Build all software under this directory
#   make          : build every test
#   make clean    : remove all build outputs
#   make <dir>    : build one group (e.g. make dhrystone)
#------------------------------------------------------------------
SUBDIRS = c_tests riscv-isa-tests dhrystone coremark

.PHONY: all clean $(SUBDIRS)

all: $(SUBDIRS)

$(SUBDIRS):
	@echo "===== $@ ====="
	@$(MAKE) -C $@ --no-print-directory

clean:
	@for d in $(SUBDIRS); do $(MAKE) -C $$d clean --no-print-directory; done
