#!/usr/bin/env python3
"""Fires a burst of jobs at distributed-job-queue's API, for the Day 10 HPA
proof: submit a backlog all at once, then watch the worker HPA react to it.

This is deliberately not distributed-job-queue's own
load_tests/locustfile.py. That file ramps simulated users over a sustained
run to measure steady-state throughput; this script exists to create one
instant spike so the three build-plan terminals (`kubectl get hpa -w`,
`kubectl get pods -w`, this script) can capture the timings the benchmark
table asks for: time from load start to first scale-up, time to stabilise,
and the scale-down delay once the backlog clears.

Job payloads are ported from that same locustfile's payload_for(), not
reinvented, so a submitted job is one a worker can actually execute rather
than synthetic data that dead-letters on the first attempt and never
touches queue_depth the way a real burst would.

No dependencies beyond the standard library. This runs from an operator's
workstation against whatever --host points at, not inside a container
image with FastAPI's own dependencies already installed, so reaching for
httpx or requests here would be one more thing to pip install before the
one command the build plan says to run.

Usage:
    python scripts/submit_jobs.py --count 5000
    python scripts/submit_jobs.py --count 5000 --host http://localhost:8000 --concurrency 50
"""

from __future__ import annotations

import argparse
import json
import random
import time
import urllib.error
import urllib.request
import uuid
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field

JOB_TYPES = ("transform.csv", "validate.rows", "compute.aggregate")

# Matches load_tests/locustfile.py: small enough that a worker's handler
# time does not dominate the measurement, so what gets observed is queue
# behaviour, not handler performance.
RECORD_COUNT = 20


def payload_for(job_type: str) -> dict:
    records = [
        {
            "id": index % 15,
            "date": "01/02/2026",
            "region": "north" if index % 2 else "south",
            "amount": index * 3,
            "note": None,
        }
        for index in range(RECORD_COUNT)
    ]
    if job_type == "transform.csv":
        return {
            "source": "load.csv",
            "records": records,
            "operations": ["deduplicate", "normalize_dates", "fill_nulls"],
        }
    if job_type == "validate.rows":
        return {
            "records": records,
            "rules": {"required": ["id"], "types": {"id": "integer", "region": "string"}},
        }
    return {"records": records, "group_by": "region", "metrics": {"amount": "sum"}}


@dataclass
class Results:
    accepted: int = 0
    duplicates: int = 0
    failed: int = 0
    errors: list[str] = field(default_factory=list)


def submit_one(host: str, timeout: float) -> tuple[int, str | None]:
    """Returns (http_status, error_message). error_message is None on any
    response the server actually sent back, including 409, which is a real
    answer, not a failure to reach it."""
    # 80/20 normal/high, the same ratio locustfile.py uses and for the same
    # reason: high priority that is not the exception stops meaning
    # anything as a signal.
    priority = "high" if random.random() < 0.2 else "normal"
    job_type = random.choice(JOB_TYPES)
    body = json.dumps(
        {
            "job_id": str(uuid.uuid4()),
            "job_type": job_type,
            "priority": priority,
            "payload": payload_for(job_type),
        }
    ).encode("utf-8")

    request = urllib.request.Request(
        f"{host.rstrip('/')}/jobs",
        data=body,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.status, None
    except urllib.error.HTTPError as exc:
        # A 409 (duplicate job_id) is the server working correctly, not a
        # submission failure. UUIDs make it vanishingly unlikely here, but
        # treating it as anything other than a real HTTP status would hide
        # a genuine dedup collision if one ever happened.
        return exc.code, None
    except urllib.error.URLError as exc:
        return 0, str(exc.reason)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--host", default="http://localhost:8000", help="distributed-job-queue API base URL")
    parser.add_argument("--count", type=int, default=1000, help="number of jobs to submit")
    parser.add_argument("--concurrency", type=int, default=50, help="parallel submitting workers")
    parser.add_argument("--timeout", type=float, default=10.0, help="per-request timeout in seconds")
    args = parser.parse_args()

    print(f"Submitting {args.count} jobs to {args.host} with {args.concurrency} concurrent workers...")
    print("Watch the reaction in two other terminals:")
    print("  kubectl get hpa -n platform -w")
    print("  kubectl get pods -n platform -l app.kubernetes.io/component=worker -w")
    print()

    results = Results()
    start = time.monotonic()

    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures = [pool.submit(submit_one, args.host, args.timeout) for _ in range(args.count)]
        for future in as_completed(futures):
            status, error = future.result()
            if error is not None:
                results.failed += 1
                if len(results.errors) < 5:
                    results.errors.append(error)
            elif status == 202:
                results.accepted += 1
            elif status == 409:
                results.duplicates += 1
            else:
                results.failed += 1
                if len(results.errors) < 5:
                    results.errors.append(f"HTTP {status}")

    elapsed = time.monotonic() - start
    rate = args.count / elapsed if elapsed > 0 else 0.0

    print(f"Done in {elapsed:.1f}s ({rate:.0f} jobs/s submitted).")
    print(f"  accepted:   {results.accepted}")
    print(f"  duplicates: {results.duplicates}")
    print(f"  failed:     {results.failed}")
    if results.errors:
        print("  sample errors:")
        for message in results.errors:
            print(f"    - {message}")

    print()
    print("Submission is only half the number the benchmark table wants.")
    print("Record time-to-first-scale-up and time-to-stabilise from the")
    print("kubectl get hpa -w terminal, and read the actual backlog left")
    print("behind from queue_depth{stream=...} in Prometheus, not from")
    print("this script's own count: this measures what the API accepted,")
    print("not what the workers have drained yet.")


if __name__ == "__main__":
    main()
