SHELL := /bin/bash
.DEFAULT_GOAL := publish

.PHONY: publish
publish:
	$(MAKE) -C haproxy publish

include Makefile.help
include Makefile.functions
