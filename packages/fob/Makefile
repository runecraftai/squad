.PHONY: build test fmt lint dist install clean demo

VERSION ?= dev
LDFLAGS := -X main.version=$(VERSION)

build:
	go build -ldflags "$(LDFLAGS)" -o fob .

test:
	go test ./...

fmt:
	gofmt -w .

lint:
	gofmt -l .
	go vet ./...

dist:
	@mkdir -p dist
	GOOS=darwin GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/fob-darwin-arm64 .
	GOOS=darwin GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/fob-darwin-amd64 .
	GOOS=linux GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/fob-linux-arm64 .
	GOOS=linux GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/fob-linux-amd64 .
	GOOS=windows GOARCH=arm64 go build -ldflags "$(LDFLAGS)" -o dist/fob-windows-arm64.exe .
	GOOS=windows GOARCH=amd64 go build -ldflags "$(LDFLAGS)" -o dist/fob-windows-amd64.exe .

install: build
	cp fob $(GOPATH)/bin/ 2>/dev/null || cp fob /usr/local/bin/

demo: build
	vhs demo.tape

clean:
	rm -rf fob dist/ coverage.out
