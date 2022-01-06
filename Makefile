SHELL := /bin/bash
.DEFAULT_GOAL := publish

.PHONY: publish
publish:
	$(MAKE) -c haproxy publish

include Makefile.help
include Makefile.functions
