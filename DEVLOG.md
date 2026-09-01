# DEVLOG

## Day 4 (31 Aug): first Helm chart, event-ingestion-api

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

## Day 7 content, taken early (1 Sep): distributed-job-queue chart

Jumped to the Day 7 application charts rather than the Day 5 and 6 stateful
services. The reasoning was that the api and worker charts are variations on
the Day 4 pattern while it is still fresh, and the StatefulSet work is a
different problem that does not build on it. The cost is that nothing can
actually be installed until Postgres and Redis exist, so this chart is
written against services that are not running yet. Days 5 and 6 come next.

**The migration race, and moving alembic out of the container.**
Project 2's api image runs `alembic upgrade head && uvicorn ...` as one
command. That is correct for docker-compose, where there is one api
container. It is a race on Kubernetes: with replicaCount 2, a fresh install
starts both pods at once and both run the same migration concurrently.
Alembic takes no lock, so two processes can apply the same revision at the
same time. The same thing happens on any rolling update with maxSurge above
zero.

Fixed with a pre-install and pre-upgrade hook Job that runs the migration
once, plus a `command:` override on the api Deployment so the containers
skip straight to uvicorn. Helm blocks the release until the Job succeeds,
which has a second benefit worth naming: a failed migration now means the
Deployment is never touched at all, instead of pods crash looping on a half
applied schema.

**The health endpoint problem is the exact inverse of Project 1's.**
Project 1's `/health` returns 503 when a dependency is down, which is why
its liveness probe had to be a TCP check: an HTTP liveness probe there
restarts every replica during a database blip.

Project 2's `/health` always returns 200, with the degraded state in the
JSON body. There is a comment in the source saying so deliberately, and for
liveness it is exactly right, so the api's liveness probe here is a normal
httpGet.

But it makes readiness impossible. Kubelet reads the status code and never
the body, so a readiness probe against this endpoint cannot ever mark a pod
unready, no matter how unreachable Redis and Postgres are. The probe is
still wired up because it does catch a process that is not answering at all,
but it is doing about half the job readiness is supposed to do.

Two services, opposite mistakes, same root cause: one endpoint being asked
to answer two different questions. Both repos need the same split into
`/health/live` and `/health/ready`. Worth doing as one change across all
three projects rather than patching each when it bites.

**Deviated from the README's autoscaling table for the api.**
The table lists Redis stream depth for both rows of this project. That is
right for the worker and wrong for the api. The api is a producer: it
accepts requests and enqueues. Queue depth is a fact about whether the
consumers are keeping up, not about whether the api needs capacity. Scaling
on it gives two wrong behaviours, scaling the api up while it sits idle
whenever workers fall behind, and leaving it flat during a real request
spike whenever the queue happens to be short. The api scales on request rate,
matching what api-gateway will do. The table in the README needs updating.

**The worker's TCP probes are better signal than they look.**
The worker runs no HTTP server beyond its Prometheus listener, so all three
probes are TCP checks on the metrics port. That reads like a weak fallback
but is not, because `worker/main.py` calls `ensure_consumer_groups()` before
`start_metrics_server()`. The port only accepts once Redis has been reached.
A worker that cannot reach Redis never opens it and never passes startup.

What it cannot detect is Redis going away later. The port stays open and the
worker's retry loop handles reconnection, which is the right place for that
to be handled, but it does make these probes a startup gate rather than a
continuous check.

**Worker termination grace is 60s, double the api's.**
On SIGTERM the worker finishes its current batch before exiting. Killing it
sooner means the in flight message is never acknowledged, so another worker
reclaims it after STALE_AFTER_MS and runs it again. The job succeeded and
then ran twice, which is a duplicate that is genuinely hard to explain from
the logs afterwards.

**Validated without a cluster, and without Helm.**
Helm is still not installed on this workstation, so `helm lint` and
`helm template` have not run against either chart. Wrote a check instead
that extracts every `.Values.*` path referenced across the templates and
resolves each one against values.yaml: 82 paths, all resolve. Also verified
Go template block balance per file and that the plain YAML parses. That
catches the typo class of error, not rendering semantics. Install Helm
before Day 5.

**Open items:**

- `/health/live` and `/health/ready` needed in Projects 1 and 2 both.
- README component table says the api scales on queue depth. It does not.
- prometheus-adapter must publish `redis_stream_length_total{queue="jobs"}`
  as a single summed series across jobs.high, jobs.normal and jobs.low. HPA
  reads one value per external metric, so the sum belongs in the adapter's
  PromQL rule, not the HPA spec.
- `http_requests_per_second` for the api HPA needs the same treatment.
- Neither chart has a PodDisruptionBudget yet. Day 12.
- `image.registry` still a placeholder in both charts.
