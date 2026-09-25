# 1단계: 빌드 환경 (GCC + CMake)
FROM alpine:3.19 AS builder
RUN apk add --no-cache build-base cmake

WORKDIR /app
COPY CMakeLists.txt protocol.h main.cpp ./

RUN mkdir build && cd build && \
    cmake -DCMAKE_BUILD_TYPE=Release .. && \
    cmake --build .

# 2단계: 런타임 환경 (초경량 Alpine 베이스)
FROM alpine:3.19
RUN apk add --no-cache libstdc++

WORKDIR /app
COPY --from=builder /app/build/sfu_server /app/sfu_server

# UDP 9999 포트 오픈
EXPOSE 9999/udp

# 실행 명령
ENTRYPOINT ["/app/sfu_server"]
CMD ["9999"]
