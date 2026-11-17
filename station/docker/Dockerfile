# still.fail's station in a container: the machine the station and its agents run on, not the station itself.
#   docker run -d --name stillfail --restart unless-stopped -v stillfail:/home/stillfail \
#     ghcr.io/afk-surf/stillfail-station <token> [<lock>] [rig:<person>]
# The release is not in the image (the user, 2026-11-17: 镜像管环境，station 自己升级): the entrypoint installs it into
# the volume on the first start, with the installer the cloud serves, and the station updates itself there as on any
# machine, handing over in place so that no turn, terminal or job stops (cloud/src/install.ts). A new image is needed
# only for what the system gives (its packages, git, the tools below), and replacing the container keeps everything
# in the volume: the home, the station's data at ~/.stillfail, the agents' logins and what they installed there.
FROM debian:bookworm-slim

# What the installer and the station call (curl, tar, ps, ionice and nice), what the agents work with (git, ssh,
# a compiler, Python, ripgrep, jq), and tini to reap what the agents leave behind.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl tar gzip xz-utils zstd unzip procps util-linux tini sudo locales tzdata \
      git git-lfs openssh-client less nano build-essential pkg-config python3 python3-venv python3-pip ripgrep jq \
 && rm -rf /var/lib/apt/lists/* \
 && sed -i 's/^# *\(en_US.UTF-8\)/\1/' /etc/locale.gen && locale-gen

# One user the station and its agents run as (the installer refuses no one, but a station is a user's, not root's),
# allowed sudo for what an agent installs from the system's packages: those last only as long as the container does,
# what is in the home lasts across images.
ARG UID=1000
RUN useradd --create-home --uid "$UID" --shell /bin/bash stillfail \
 && echo 'stillfail ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/stillfail && chmod 0440 /etc/sudoers.d/stillfail

COPY entrypoint.sh /usr/local/bin/stillfail-container
RUN chmod 0755 /usr/local/bin/stillfail-container

USER stillfail
WORKDIR /home/stillfail
ENV HOME=/home/stillfail \
    LANG=en_US.UTF-8 \
    PATH=/home/stillfail/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    STILLFAIL_CONTAINER=1
VOLUME ["/home/stillfail"]

# (tini passes a stop to the entrypoint, which ends the station as its SIGTERM says, then whatever is left with it)
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/stillfail-container"]
