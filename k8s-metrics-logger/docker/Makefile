SHELL := /bin/bash
BASE_DIR := ../..
APP_VERSION := $(shell yq -r ".appVersion" ../Chart.yaml)
VERSION := $(shell yq -r ".version" ../Chart.yaml)
NAME := $(shell yq -r ".name" ../Chart.yaml)
.DEFAULT_GOAL := all

.PHONY: all
all: build push ##@default Build docker image and push it to docker-hub.

.PHONY: build
build: ##@default Build docker image.
	docker build -t docker.io/robobeerun/${NAME}:${APP_VERSION} .

.PHONY: push
push: ##@default Push the build docker image to docker-hub.
	docker push docker.io/robobeerun/${NAME}:${APP_VERSION}

include $(BASE_DIR)/Makefile.help
include $(BASE_DIR)/Makefile.functions
