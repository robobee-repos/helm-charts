SHELL := /bin/bash
.DEFAULT_GOAL := publish-all

.PHONY: publish-all
publish-all: publish index push

.PHONY: publish
publish:
	$(MAKE) -C haproxy publish
	$(MAKE) -C kube-postgres-operator-crunchy/helm/install publish

.PHONY: index
index:
	cd charts && helm repo index .

.PHONY: push
push:
	git add . && git commit -a -m "Publish charts." && git push

include Makefile.help
include Makefile.functions
