# still.fail's station container (for agents)

- The image is the machine, never the station (the user, 2026-11-17: 镜像管环境，station 自己升级): no release goes in
  it. The entrypoint installs the release into the volume with the cloud's installer, and the station updates itself
  there, handing over in place like on any machine, so no turn, terminal or job stops. Replacing the container would
  stop all of them, so it is only for what the system gives (packages, tools).
- Everything that lasts is in the one volume, the home (`/home/stillfail`): the data at `~/.stillfail`, the agents'
  logins and what they installed there. What goes in through `sudo apt-get` lasts only as long as the container.
- The installer knows it runs here by `STILLFAIL_CONTAINER` (`cloud/src/install.ts`): it starts nothing, and a restart
  only ends the running station. The entrypoint starts it again once the installer lets go of its lock in the data
  (run/install.lock).
- `.github/workflows/station-docker.yml` builds it for x64 and arm64, runs `smoke.sh` and, on main, pushes it to
  `ghcr.io/afk-surf/stillfail-station`.
