# releases

Released versions of each app's chart: `releases/<app>/<version>/` is a copy of `helm/<app>/` as it was when that version was released, and is never edited afterwards.

- dev runs `helm/<app>/` as it is. staging and prod run the release their env file pins: `chartVersion: 0.2.0` in `cd/<app>/staging.yaml` means `releases/<app>/0.2.0/`, with today's `cd/<app>/values.yaml` and `staging.yaml`. A chart change reaches staging and prod only when their `chartVersion` is bumped, like an image.
- Release: `./pipeline ci <app> --chart 0.2.0` sets `version: 0.2.0` in `helm/<app>/Chart.yaml` and copies `helm/<app>/` here. A version that already has a folder is refused.
- Promote: change `chartVersion` in the env file (a PR, or locally `./pipeline cd <app> staging --chart 0.2.0`). Roll back by setting it back.
- A folder no environment pins any more can be deleted.

In production, a released chart would be published as a versioned package (OCI, e.g. to GHCR) instead of a folder in Git: see `docs/production-on-aws.md`.
