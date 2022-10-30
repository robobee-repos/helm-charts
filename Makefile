SHELL := /bin/bash
.DEFAULT_GOAL := publish-all

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
	$(MAKE) -C openldap publish
	$(MAKE) -C nextcloud-helm/charts/nextcloud publish
	$(MAKE) -C jenkins publish
	$(MAKE) -C matomo publish
	$(MAKE) -C ingress publish
	$(MAKE) -C minio-kes publish
	$(MAKE) -C gitea-helm-chart publish
	$(MAKE) -C k8s-resources-job publish
	$(MAKE) -C nexus-operator publish
	$(MAKE) -C nexus publish

.PHONY: publish-harbor-all
publish-harbor-all: ##@targets Publish all helm charts to private harbor.
	$(MAKE) -C haproxy publish-harbor
	$(MAKE) -C kube-postgres-operator-crunchy/helm/install publish-harbor
	$(MAKE) -C kube-postgres-operator-crunchy/helm/postgres publish-harbor
	$(MAKE) -C certs-issuers publish-harbor
	$(MAKE) -C certs publish-harbor
	$(MAKE) -C openldap publish-harbor
	$(MAKE) -C nextcloud-helm/charts/nextcloud publish-harbor
	$(MAKE) -C jenkins publish-harbor
	$(MAKE) -C matomo publish-harbor
	$(MAKE) -C ingress publish-harbor
	$(MAKE) -C minio-kes publish-harbor
	$(MAKE) -C gitea-helm-chart publish-harbor
	$(MAKE) -C k8s-resources-job publish-harbor
	$(MAKE) -C nexus-operator publish-harbor
	$(MAKE) -C nexus publish-harbor

.PHONY: index
index:
	cd charts && helm repo index .

.PHONY: push
push:
	git add . && git commit --allow-empty -a -m "Publish charts." && git push

include Makefile.help
include Makefile.functions
