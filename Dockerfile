FROM localhost/tcl-core-x86_64:17.0

ENV TC_ISO_URL="${TC_ISO_URL:-http://www.tinycorelinux.net/17.x/x86_64/release/TinyCorePure64-17.0.iso}"

# fix sudoers ownership: cpio extraction on non-root hosts leaves it owned by the build user
RUN chown 0:0 /etc/sudoers

# create runtime directories that TinyCore's init normally sets up at boot
RUN mkdir -p /tmp/tce/optional /home/tc && \
    chown -R tc:staff /tmp/tce /home/tc && \
    echo "http://tinycorelinux.net" > /opt/tcemirror

# in relation to issue #3,
# try to capture error state while running tce-load command
USER tc
RUN tce-load -wic bash.tcz libisoburn.tcz git.tcz gcc.tcz compiletc.tcz
USER root

# get rid of pre-registered packages
RUN rm -rf /tmp/tce/optional/*

# also in relation to #3,
# double-check via tce-status if given packages are actually installed
RUN tce-status -i | grep -Ee '^(bash|libisoburn|git|gcc|compiletc)$'

ADD files /tmp/build 

USER root:root
ENTRYPOINT /tmp/build/build.sh
