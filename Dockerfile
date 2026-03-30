FROM localhost/tcl-core-x86_64:17.0

ENV TC_ISO_URL="${TC_ISO_URL:-http://www.tinycorelinux.net/17.x/x86_64/release/TinyCorePure64-17.0.iso}"

# TinyCore installs libs to /usr/local/lib; rebuild linker cache so packages
# extracted via unsquashfs (not mounted via squashfs union) are found at runtime
ENV LD_LIBRARY_PATH=/usr/local/lib

# Set up TinyCore runtime environment needed by build.sh (tce-load for cpupower, sudo calls)
RUN chown 0:0 /etc/sudoers && \
    chmod u+s /usr/bin/sudo && \
    mkdir -p /tmp/tce/optional /home/tc /usr/local/tce.installed /etc/sysconfig && \
    chown -R tc:staff /tmp/tce /home/tc && \
    echo "http://tinycorelinux.net" > /opt/tcemirror && \
    ln -sf /tmp/tce /etc/sysconfig/tcedir && \
    ldconfig 2>/dev/null || true

# Verify build tools pre-installed by build-base-image.sh are accessible
RUN bash --version > /dev/null && \
    xorriso --version > /dev/null 2>&1 && \
    git --version > /dev/null && \
    gcc --version > /dev/null

ADD files /tmp/build

USER root:root
ENTRYPOINT /tmp/build/build.sh
