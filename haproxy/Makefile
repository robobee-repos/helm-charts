SHELL := /bin/bash
.DEFAULT_GOAL := publish

.PHONY: publish
publish: package index push

.PHONY: package
package:
	helm package .

.PHONY: index
index:
	VERSION=`yq e '.version' Chart.yaml` && \
	mv haproxy-$${VERSION}.tgz ../charts
	cd ../charts && helm repo index .

.PHONY: push
push:
	VERSION=`yq e '.version' Chart.yaml` && \
	cd .. && git add . && git commit -a -m "Publish $${VERSION}"

include ../Makefile.help
include ../Makefile.functions
