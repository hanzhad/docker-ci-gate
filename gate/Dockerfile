# The gate — the design docs.
#
# It holds the credential and decides how many runners exist. It never executes
# anything from a repository, which is the whole reason it is a separate
# container from the runners it starts: the runner is where a pull request's
# own code runs, and it holds nothing but a credential good for one job.
#
# Small on purpose. Everything it does is four HTTP calls and `docker run`, so
# anything else in here would be attack surface bought for nothing.
FROM alpine:3.22

RUN apk add --no-cache bash curl jq docker-cli tini

COPY gate.sh unlock.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/gate.sh /usr/local/bin/unlock.sh

# The commit this image was built from, put there by `ci-runner.sh build` and
# `redeploy`, so the gate can say which code it runs: in its log line and in
# status.json. After the layers above, so a new commit only redoes this one.
ARG GATE_COMMIT=unknown
ENV GATE_COMMIT=$GATE_COMMIT

# tini, because the loop spawns `docker` children and stopping the gate from
# Docker Desktop has to be a clean SIGTERM that reaches the trap — that trap is
# what removes the idle runners, and without it stopping the gate would leave
# them behind for somebody to find later and wonder about.
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/gate.sh"]
