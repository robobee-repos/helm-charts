SHELL := /bin/bash
BASE_DIR := ..
VERSION := $(shell yq e ".version" Chart.yaml)
APP_VERSION := $(shell yq e ".appVersion" Chart.yaml)
NAME := $(shell yq e ".name" Chart.yaml)
.DEFAULT_GOAL := publish

.PHONY: publish
publish: package

.PHONY: publish-harbor
publish-harbor:
	helm cm-push . robobeerun

.PHONY: package
package: $(BASE_DIR)/charts/$(NAME)-$(VERSION).tgz

.PHONY: update-index
update-index:
	cd ../charts && sed -i -e "s/%GITEA_VERSION%/$(VERSION)/" index.html
	cd ../charts && sed -i -e "s/%GITEA_APP_VERSION%/$(APP_VERSION)/" index.html

$(BASE_DIR)/charts/$(NAME)-$(VERSION).tgz:
	helm package .
	mv $(NAME)-$(VERSION).tgz $(BASE_DIR)/charts

include $(BASE_DIR)/Makefile.help
include $(BASE_DIR)/Makefile.functions
