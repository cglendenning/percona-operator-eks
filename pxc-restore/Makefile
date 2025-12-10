.PHONY: build run clean test

# Build the binary
build:
	go build -o pxc-restore-server main.go

# Run the server
run:
	go run main.go

# Clean build artifacts
clean:
	rm -f pxc-restore-server

# Build for multiple platforms
build-all:
	GOOS=linux GOARCH=amd64 go build -o dist/pxc-restore-server-linux-amd64 main.go
	GOOS=darwin GOARCH=amd64 go build -o dist/pxc-restore-server-darwin-amd64 main.go
	GOOS=darwin GOARCH=arm64 go build -o dist/pxc-restore-server-darwin-arm64 main.go

# Install CLI
install-cli:
	chmod +x cli/pxc-restore
	cp cli/pxc-restore /usr/local/bin/pxc-restore || sudo cp cli/pxc-restore /usr/local/bin/pxc-restore
	@echo "CLI installed to /usr/local/bin/pxc-restore"
