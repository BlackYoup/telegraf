PREFIX := /usr/local
VERSION := $(shell git describe --exact-match --tags 2>/dev/null)
BRANCH := $(shell git rev-parse --abbrev-ref HEAD)
COMMIT := $(shell git rev-parse --short HEAD)
GOFILES ?= $(shell git ls-files '*.go')
GOFMT ?= $(shell gofmt -l $(GOFILES))

ifdef GOBIN
PATH := $(GOBIN):$(PATH)
else
PATH := $(subst :,/bin:,$(GOPATH))/bin:$(PATH)
endif

TELEGRAF := telegraf$(shell go tool dist env | grep -q 'GOOS=.windows.' && echo .exe)

LDFLAGS := $(LDFLAGS) -X main.commit=$(COMMIT) -X main.branch=$(BRANCH)
ifdef VERSION
	LDFLAGS += -X main.version=$(VERSION)
endif

all:
	$(MAKE) fmtcheck
	$(MAKE) deps
	$(MAKE) telegraf

ci-test:
	$(MAKE) deps
	$(MAKE) fmtcheck
	$(MAKE) vet
	$(MAKE) test

deps:
	go get -u github.com/golang/lint/golint
	go get github.com/sparrc/gdm
	gdm restore

telegraf:
	go build -i -o $(TELEGRAF) -ldflags "$(LDFLAGS)" ./cmd/telegraf/telegraf.go

go-install:
	go install -ldflags "-w -s $(LDFLAGS)" ./cmd/telegraf

install: telegraf
	mkdir -p $(DESTDIR)$(PREFIX)/bin/
	cp $(TELEGRAF) $(DESTDIR)$(PREFIX)/bin/

test:
# Use the windows godeps file to prepare dependencies
prepare-windows:
	go get github.com/sparrc/gdm
	gdm restore
	gdm restore -f Godeps_windows

# Run all docker containers necessary for unit tests
docker-run:
	docker run --name aerospike -p "3000:3000" -d aerospike/aerospike-server:3.9.0
	docker run --name kafka \
		-e ADVERTISED_HOST=localhost \
		-e ADVERTISED_PORT=9092 \
		-p "2181:2181" -p "9092:9092" \
		-d spotify/kafka
	docker run --name mysql -p "3306:3306" -e MYSQL_ALLOW_EMPTY_PASSWORD=yes -d mysql
	docker run --name memcached -p "11211:11211" -d memcached
	docker run --name postgres -p "5432:5432" -d postgres
	docker run --name rabbitmq -p "15672:15672" -p "5672:5672" -d rabbitmq:3-management
	docker run --name redis -p "6379:6379" -d redis
	docker run --name nsq -p "4150:4150" -d nsqio/nsq /nsqd
	docker run --name mqtt -p "1883:1883" -d ncarlier/mqtt
	docker run --name riemann -p "5555:5555" -d blalor/riemann
	docker run --name nats -p "4222:4222" -d nats
	docker run --name warp10 -p "8090:8080" -p "8091:8081" -d -i warp10io/warp10:1.0.16-ci

# Run docker containers necessary for CircleCI unit tests
docker-run-circle:
	docker run --name aerospike -p "3000:3000" -d aerospike/aerospike-server:3.9.0
	docker run --name kafka \
		-e ADVERTISED_HOST=localhost \
		-e ADVERTISED_PORT=9092 \
		-p "2181:2181" -p "9092:9092" \
		-d spotify/kafka
	docker run --name nsq -p "4150:4150" -d nsqio/nsq /nsqd
	docker run --name mqtt -p "1883:1883" -d ncarlier/mqtt
	docker run --name riemann -p "5555:5555" -d blalor/riemann
	docker run --name nats -p "4222:4222" -d nats
	docker run --name warp10 -p "8090:8080" -p "8091:8081" -d -i waxzce/warp10forci:latest

# Kill all docker containers, ignore errors
docker-kill:
	-docker kill nsq aerospike redis rabbitmq postgres memcached mysql kafka mqtt riemann nats
	-docker rm nsq aerospike redis rabbitmq postgres memcached mysql kafka mqtt riemann nats

# Run full unit tests using docker containers (includes setup and teardown)
test: vet docker-kill docker-run
	# Sleeping for kafka leadership election, TSDB setup, etc.
	sleep 60
	# SUCCESS, running tests
	go test -race ./...

# Run "short" unit tests
test-short: vet
	go test -short ./...

fmt:
	@gofmt -w $(GOFILES)

fmtcheck:
	@echo '[INFO] running gofmt to identify incorrectly formatted code...'
	@if [ ! -z $(GOFMT) ]; then \
		echo "[ERROR] gofmt has found errors in the following files:"  ; \
		echo "$(GOFMT)" ; \
		echo "" ;\
		echo "Run make fmt to fix them." ; \
		exit 1 ;\
	fi
	@echo '[INFO] done.'

lint:
	golint ./...

test-windows:
	go test ./plugins/inputs/ping/...
	go test ./plugins/inputs/win_perf_counters/...
	go test ./plugins/inputs/win_services/...
	go test ./plugins/inputs/procstat/...

# vet runs the Go source code static analysis tool `vet` to find
# any common errors.
vet:
	@echo 'go vet $$(go list ./...)'
	@go vet $$(go list ./...) ; if [ $$? -eq 1 ]; then \
		echo ""; \
		echo "go vet has found suspicious constructs. Please remediate any reported errors"; \
		echo "to fix them before submitting code for review."; \
		exit 1; \
	fi

test-all: vet
	go test ./...

package:
	./scripts/build.py --package --platform=all --arch=all

clean:
	rm -f telegraf
	rm -f telegraf.exe

docker-image:
	./scripts/build.py --package --platform=linux --arch=amd64
	cp build/telegraf*$(COMMIT)*.deb .
	docker build -f scripts/dev.docker --build-arg "package=telegraf*$(COMMIT)*.deb" -t "telegraf-dev:$(COMMIT)" .

.PHONY: deps telegraf install test test-windows lint vet test-all package clean docker-image fmtcheck
