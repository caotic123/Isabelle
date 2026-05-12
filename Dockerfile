# syntax=docker/dockerfile:1

FROM ubuntu:22.04 AS cvc5-builder

ARG DEBIAN_FRONTEND=noninteractive
ARG CVC5_CONFIGURE_ARGS="production --auto-download --static-binary"
ARG CVC5_BUILD_JOBS=2

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      autoconf \
      automake \
      bison \
      build-essential \
      ca-certificates \
      cmake \
      flex \
      git \
      libedit-dev \
      libgmp-dev \
      libtool \
      pkg-config \
      python3 \
      python3-pip \
      python3-venv \
      wget && \
    pip3 install --no-cache-dir tomli pyparsing && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /src/cvc5
COPY third_party/cvc5 /src/cvc5

RUN ./configure.sh ${CVC5_CONFIGURE_ARGS}
RUN cmake --build build --target cvc5-bin --parallel "${CVC5_BUILD_JOBS}" && \
    test -x build/bin/cvc5 && \
    build/bin/cvc5 --version

FROM ubuntu:22.04

ARG DEBIAN_FRONTEND=noninteractive
ARG USER_ID=1000
ARG GROUP_ID=1000
ARG BUILD_SESSION=false
ARG ISABELLE_COMPONENTS="bash_process-20240326 e-3.2 flatlaf-3.6.1 gnu-utils-20211030 isabelle_fonts-20241227 isabelle_setup-20250613 jdk-21.0.8 jedit-20250825 jfreechart-1.5.3 jortho-1.0-2 jsoup-1.18.3 jsvg-2.0.0 kodkodi-1.5.7 polyml-5.9.1-1 scala-3.3.4 sqlite-3.49.1.0 verit-2021.06.2-rmx-1 xz-java-1.10 zstd-jni-1.5.7-4"

LABEL org.opencontainers.image.title="Isabelle Abduct Artifact"
LABEL org.opencontainers.image.description="Containerized Isabelle checkout with bundled cvc5 and Abduct smoke tests."

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      bash \
      ca-certificates \
      curl \
      file \
      fonts-dejavu-core \
      fonts-dejavu-extra \
      libasound2 \
      libfontconfig1 \
      libfreetype6 \
      libgmp10 \
      libgtk-3-0 \
      libnss3 \
      libx11-6 \
      libxext6 \
      libxi6 \
      libxinerama1 \
      libxrandr2 \
      libxrender1 \
      libxtst6 \
      locales \
      perl \
      procps \
      python3 \
      tar \
      unzip \
      xauth \
      xdg-utils \
      xvfb \
      xz-utils \
      zip \
      zstd && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --gid "${GROUP_ID}" isabelle && \
    useradd --uid "${USER_ID}" --gid "${GROUP_ID}" --create-home --shell /bin/bash isabelle

WORKDIR /opt/isabelle
COPY --chown=isabelle:isabelle . /opt/isabelle
RUN mkdir -p /opt/isabelle/contrib/cvc5/bin /opt/isabelle/contrib/cvc5/lib && \
    chown -R isabelle:isabelle /opt/isabelle/contrib/cvc5
COPY --from=cvc5-builder --chown=isabelle:isabelle /src/cvc5/build/bin/cvc5 /opt/isabelle/contrib/cvc5/bin/cvc5
COPY --from=cvc5-builder --chown=isabelle:isabelle /src/cvc5/build/src/libcvc5.so.1 /opt/isabelle/contrib/cvc5/lib/libcvc5.so.1
COPY --from=cvc5-builder --chown=isabelle:isabelle /src/cvc5/build/src/parser/libcvc5parser.so.1 /opt/isabelle/contrib/cvc5/lib/libcvc5parser.so.1
COPY --from=cvc5-builder --chown=isabelle:isabelle /src/cvc5/build/deps/lib/libpoly.so.0 /opt/isabelle/contrib/cvc5/lib/libpoly.so.0
COPY --from=cvc5-builder --chown=isabelle:isabelle /src/cvc5/build/deps/lib/libpolyxx.so.0 /opt/isabelle/contrib/cvc5/lib/libpolyxx.so.0

USER isabelle

ENV HOME=/home/isabelle
ENV USER_HOME=/home/isabelle
ENV ISABELLE_HOME=/opt/isabelle
ENV CVC5=/opt/isabelle/contrib/cvc5/bin/cvc5
ENV LD_LIBRARY_PATH=/opt/isabelle/contrib/cvc5/lib
ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PATH=/opt/isabelle/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

RUN ./bin/isabelle components -I && \
    { \
      echo ''; \
      echo 'ISABELLE_TOOL_JAVA_OPTIONS="-Djava.awt.headless=true -Xms256m -Xmx1536m -Xss16m"'; \
      echo 'ML_OPTIONS="--minheap 64 --maxheap 1600"'; \
      echo 'CVC5="/opt/isabelle/contrib/cvc5/bin/cvc5"'; \
      echo 'LD_LIBRARY_PATH="/opt/isabelle/contrib/cvc5/lib:${LD_LIBRARY_PATH:-}"'; \
    } >> "${HOME}/.isabelle/etc/settings" && \
    ./bin/isabelle components ${ISABELLE_COMPONENTS} && \
    "${CVC5}" --version

RUN for script in ./run_benchmark.sh ./run_benchmark_parallel_random.sh ./docker/smoke.sh; do \
      bash -n "${script}"; \
    done && \
    if [ "${BUILD_SESSION}" = "true" ]; then \
      ./bin/isabelle build -j1 -o threads=1 -d src/Abduct -b Abduct_Lambda_Calculus; \
    fi

ENTRYPOINT ["./docker/smoke.sh"]
CMD ["all"]
