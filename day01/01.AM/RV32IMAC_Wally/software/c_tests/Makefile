SUBDIRS = cachetest fib replace strcmp sum vecadd ftest

.PHONY: all $(SUBDIRS)
all: $(SUBDIRS)

$(SUBDIRS):
	@echo "Entering directory '$@'"
	@$(MAKE) -C $@ --no-print-directory

.PHONY: clean
clean:
	for dir in $(SUBDIRS); do \
		$(MAKE) -C $$dir clean; \
	done

