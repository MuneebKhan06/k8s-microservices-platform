# DEVLOG

## Day 4 (31 Aug) — first Helm chart: event-ingestion-api

Did one chart properly rather than three roughly. The other two application
charts are variations on this one, and getting the probe and rollout decisions
wrong here would mean getting them wrong three times.

**Namespaces committed as a manifest, not created with kubectl.**
`kubectl create namespace platform` works and leaves nothing behind that says
why there are three of them. The manifest is the record.

**Liveness is a TCP check, and this was the real decision of the day.**
Project 1 exposes a single `/health` that checks Kafka and Postgres and
returns 503 when either is down. That is correct for readiness and actively
harmful for liveness. If Postgres goes away for twenty seconds, an HTTP
liveness probe on `/health` fails on every replica at once and Kubernetes
restarts the entire deployment. A recoverable database blip becomes a crash
loop, and the restarts hit Postgres with a reconnect storm exactly when it is
already struggling.

So liveness checks that the socket accepts, which answers the only question
liveness should ask: is this process alive. Readiness keeps `/health` and
correctly pulls a pod out of the Service when its dependencies are gone.

The proper fix belongs in the Project 1 repo: split into `/health/live`
returning 200 unless the process itself is broken, and `/health/ready`
checking dependencies. Then liveness moves to httpGet. Noting it here and in
that repo's DEVLOG because it is a change to Project 1 driven purely by a
deployment requirement, which is the kind of thing that gets lost otherwise.

**`replicas` is omitted from the Deployment when the HPA is enabled.**
Leaving it in means every `helm upgrade` writes the values file number back
into the spec and undoes whatever the HPA had scaled to. It shows up as an
unexplained scale down in the middle of a deploy and is genuinely confusing to
diagnose, because the manifest and the cluster both look correct in isolation.

**Config checksums as pod annotations.**
Editing a ConfigMap updates the object and changes nothing about the running
pods, because the pod spec is identical and there is no reason to roll. The
sha256 of the rendered ConfigMap in an annotation makes a config edit a pod
spec change, so the rollout happens.

**Two Services, one of them headless.**
Prometheus scraping through the ClusterIP would land on an arbitrary pod each
time, so a per instance rate would jump between replicas and mean nothing.
The headless Service resolves to every pod address and gives one scrape
target per replica.

**HPA on consumer lag, not CPU.**
This service can sit near idle CPU while falling steadily behind on the topic.
CPU only moves once the backlog is large, which is too late. Lag moves first.
Scale down stabilization is pinned at 300s rather than inherited, so the
number is visible in the file. Backlogs arrive in waves and a fast scale down
removes the pods that are about to be needed again.

Untested against a live cluster. The VMs are not up yet, so this is
`helm template` correct and nothing more. Day 5 is Postgres as a StatefulSet
and the storage question, which is where the first real install happens.

**Open items:**

- `readOnlyRootFilesystem` left off. The image runs uvicorn as uid 1000 and
  Python writes bytecode caches under /app. Turning it on needs a writable
  tmpfs mount and a test run to confirm nothing else writes.
- `image.registry` is a `REGISTRY_HOST:5000` placeholder until the master VM
  has an IP.
- Secret is a plain Kubernetes Secret, which is base64 and not encryption.
  `existingSecret` is in place so an External Secrets Operator managed Secret
  can replace it without touching templates.
