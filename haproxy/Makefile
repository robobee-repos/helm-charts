SHELL := /bin/bash

.PHONY: publish
publish: package index push

.PHONY: package
package:
	helm package .

.PHONY: index
index:
	$(call check_defined, VERSION, The version to publish.)
	mv haproxy-$(VERSION).tgz ../charts
	cd ../charts && helm repo index .

.PHONY: push
push:
	$(call check_defined, MESSAGE, The commit message.)
	cd .. && git add . && git commit -a -m "$(MESSAGE)" && git push

include Makefile.help
include Makefile.functions
