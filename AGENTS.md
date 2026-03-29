# Agent Instructions

- Unless specifically instructed not to, after you make a code change, you should deploy the updated app, commit, and push.
- To deploy the updated app, first terminate any existing `Scenes` processes so only one instance remains running. Prefer `pkill -f '/Scenes.app/Contents/MacOS/Scenes' || true`.
- After terminating `Scenes`, run `./install-scenes.sh` from the repo root. That script rebuilds the app, copies the new build output to `~/Applications/Scenes.app`, and relaunches it.
- After the deploy succeeds, commit your changes and push them.
