SHELL := /bin/bash
BASE_DIR := ..
APP_VERSION := $(shell yq -r ".appVersion" Chart.yaml)
VERSION := $(shell yq -r ".version" Chart.yaml)
NAME := $(shell yq -r ".name" Chart.yaml)
.DEFAULT_GOAL := publish

.PHONY: publish
publish: package

.PHONY: publish-harbor
publish-harbor:
	helm cm-push . robobeerun

.PHONY: package
package: $(BASE_DIR)/charts/$(NAME)-$(VERSION).tgz

$(BASE_DIR)/charts/$(NAME)-$(VERSION).tgz:
	helm package .
	mv $(NAME)-$(VERSION).tgz $(BASE_DIR)/charts

.PHONY: update-index
update-index:
	cd ../charts && sed -i -e "s/%SELF_SERVICE_PASSWORD_VERSION%/$(VERSION)/" index.html
	cd ../charts && sed -i -e "s/%SELF_SERVICE_PASSWORD_APP_VERSION%/$(APP_VERSION)/" index.html

include $(BASE_DIR)/Makefile.help
include $(BASE_DIR)/Makefile.functions
