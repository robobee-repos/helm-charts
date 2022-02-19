SHELL := /bin/bash
.DEFAULT_GOAL := publish-all

.PHONY: publish-all
publish-all: publish index push

.PHONY: publish
publish:
	$(MAKE) -C haproxy publish
	$(MAKE) -C kube-postgres-operator-crunchy/helm/install publish
	$(MAKE) -C kube-postgres-operator-crunchy/helm/postgres publish
	$(MAKE) -C certs-issuers publish
	$(MAKE) -C certs publish
	$(MAKE) -C openldap publish
	$(MAKE) -C nextcloud-helm/charts/nextcloud publish
	$(MAKE) -C jenkins publish
	$(MAKE) -C matomo publish

.PHONY: index
index:
	cd charts && helm repo index .

.PHONY: push
push:
	git add . && git commit -a -m "Publish charts." && git push

include Makefile.help
include Makefile.functions
