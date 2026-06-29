SHELL := /bin/bash
.DEFAULT_GOAL := publish-all

EXECUTABLES = yq
K := $(foreach exec,$(EXECUTABLES),\
        $(if $(shell which $(exec)),some string,$(error "No $(exec) in PATH")))

.PHONY: readme
readme: ##@targets Updates the README.md from the README.textile
	pandoc -f textile -t markdown_mmd -o README.md README.textile

.PHONY: publish-all
publish-all: publish index push ##@targets Publish all helm charts.

.PHONY: publish
publish:
	$(MAKE) -C haproxy publish
	$(MAKE) -C kube-postgres-operator-crunchy/helm/install publish
	$(MAKE) -C kube-postgres-operator-crunchy/helm/postgres publish
	$(MAKE) -C certs-issuers publish
	$(MAKE) -C certs publish
	$(MAKE) -C nextcloud-helm/charts/nextcloud publish
	$(MAKE) -C jenkins publish
	$(MAKE) -C matomo publish
	$(MAKE) -C ingress publish
	$(MAKE) -C minio-kes publish
	$(MAKE) -C gitea publish
	$(MAKE) -C kube-resources publish
	$(MAKE) -C nexus-operator publish
	$(MAKE) -C nexus publish
	$(MAKE) -C mariadb-jobs publish
	$(MAKE) -C openldap publish
	$(MAKE) -C self-service-password publish

.PHONY: publish-harbor-all
publish-harbor-all: ##@targets Publish all helm charts to private harbor.
	$(MAKE) -C haproxy publish-harbor
	$(MAKE) -C kube-postgres-operator-crunchy/helm/install publish-harbor
	$(MAKE) -C kube-postgres-operator-crunchy/helm/postgres publish-harbor
	$(MAKE) -C certs-issuers publish-harbor
	$(MAKE) -C certs publish-harbor
	$(MAKE) -C nextcloud-helm/charts/nextcloud publish-harbor
	$(MAKE) -C jenkins publish-harbor
	$(MAKE) -C matomo publish-harbor
	$(MAKE) -C ingress publish-harbor
	$(MAKE) -C minio-kes publish-harbor
	$(MAKE) -C gitea publish-harbor
	$(MAKE) -C kube-resources publish
	$(MAKE) -C nexus-operator publish-harbor
	$(MAKE) -C nexus publish-harbor
	$(MAKE) -C mariadb-jobs publish-harbor
	$(MAKE) -C self-service-password publish-harbor

.PHONY: index
index:
	cd charts && helm repo index .
	cd charts && sed -e "s/%TIME%/`date`/" index.html.tpl > index.html
	$(MAKE) -C gitea update-index
	$(MAKE) -C mariadb-jobs update-index
	$(MAKE) -C openldap update-index
	$(MAKE) -C certs-issuers update-index
	$(MAKE) -C self-service-password update-index

.PHONY: push
push:
	git add . && git commit --allow-empty -a -m "Publish charts." && git push

.PHONY: publish-charts-all
publish-charts-all: ##@targets Publish all helm charts to the Github repository helm-chars-charts.
	cp charts/* ../helm-charts-charts/

include Makefile.help
include Makefile.functions
