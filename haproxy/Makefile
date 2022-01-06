SHELL := /bin/bash
BASE_DIR := ..
VERSION := $(shell yq e ".version" Chart.yaml)
NAME := $(shell yq e ".name" Chart.yaml)
.DEFAULT_GOAL := publish

.PHONY: publish
publish: package

.PHONY: package
package:
	helm package .
	mv $(NAME)-$(VERSION).tgz $(BASE_DIR)/charts

include $(BASE_DIR)/Makefile.help
include $(BASE_DIR)/Makefile.functions
