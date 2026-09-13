.PHONY: build test race bench smoke clean

# Native build (this machine's arch). For the release matrix use
# ../scripts/build-core.sh (amd64 + arm64 + universal).
build:
	go build -trimpath -ldflags "-s -w" -o ../../dist/whatsapp-core-dev ./cmd/whatsapp-core

test:
	go test ./...

race:
	go test -race -count=1 ./...

# Bench with the documented 150k fixture:
#   make bench          # 50k default fixture
#   WW_BENCH_N=150000 make bench
bench:
	go test ./internal/storage -run XXX -bench . -benchmem

smoke:
	../scripts/smoke.sh

clean:
	rm -rf ../../dist
