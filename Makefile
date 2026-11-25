PI_DEVICE ?=
ANSIBLE_DIR := pi/ansible
BIRDMIC_HOST ?= birdmic.example.lan
K8S_APP := k8s/birdnet-go
export PATH := $(HOME)/.local/bin:$(PATH)

.PHONY: lint test status dev-up dev-down flash-dry flash provision unlock probe k8s-render k8s-diff

lint:
	shellcheck pi/image/flash.sh scripts/birdmic-status.sh dev/config/fetch-audio.sh
	cd $(ANSIBLE_DIR) && ansible-playbook --syntax-check site.yml && ansible-lint

# Fake mic on this machine, then check it with the status script.
test: dev-up
	sleep 10 && BIRDMIC_HOST=localhost scripts/birdmic-status.sh

dev-up:
	docker compose -f dev/docker-compose.yml up -d

dev-down:
	docker compose -f dev/docker-compose.yml down -v

status:
	BIRDMIC_HOST=$(BIRDMIC_HOST) scripts/birdmic-status.sh

flash-dry:
	pi/image/flash.sh $(if $(PI_DEVICE),--device $(PI_DEVICE))

flash:
	@test -n "$(PI_DEVICE)" || (echo "set PI_DEVICE=/dev/diskN"; exit 1)
	pi/image/flash.sh --write --device $(PI_DEVICE)

provision:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml

# Disable the read-only root, apply changes, leave the Pi writable.
unlock:
	cd $(ANSIBLE_DIR) && ansible-playbook site.yml -e birdmic_readonly=false

probe:
	ffprobe -v error -rtsp_transport tcp -show_entries stream=codec_name,sample_rate,channels rtsp://$(BIRDMIC_HOST):8554/mic

k8s-render:
	kubectl kustomize $(K8S_APP)

k8s-diff:
	kubectl diff -k $(K8S_APP)
