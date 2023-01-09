FROM golang:1.18 as builder

COPY . /pcurl
WORKDIR /pcurl/mayhem

RUN go install github.com/dvyukov/go-fuzz/go-fuzz@latest github.com/dvyukov/go-fuzz/go-fuzz-build@latest
RUN go get github.com/dvyukov/go-fuzz/go-fuzz-dep
RUN apt-get update && apt-get install -y clang

RUN go-fuzz-build -libfuzzer -o fuzzPcurl.a && \
    clang -fsanitize=fuzzer fuzzPcurl.a -o fuzzPcurl.libfuzzer

FROM debian:bookworm-slim
COPY --from=builder /pcurl/mayhem/fuzzPcurl.libfuzzer /