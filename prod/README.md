# Production — timemizwo.com

**Current reality (2026-09-23):** production runs the SAME build-on-server
docker-compose pattern as `../staging`, on the SAME office server
(221.120.236.55), side by side with staging. This was a deliberate
short-term call (fast, zero extra hosting cost) — see the "hosting decision"
discussion in project notes. Ports 9003 (nginx) / 9004 (minio) are reserved
for this stack; staging owns 9001/9002. Production uses its OWN checkout of
the four repos on the server (`~/timenova-track-prod/`, separate from
staging's `~/timenova-track/`) so a staging auto-deploy can never race a
manual prod deploy over the same git working tree — see
`../scripts/manual-deploy-prod.sh` for the one-time setup.

Known constraint worth watching: the server hosts 100+ unrelated containers
across many other client projects on only 4 CPU cores. Fine to start, but
migrate off (see the AWS target below) once real customer traffic/reliability
requirements justify it.

DB backups go off-site to AWS S3 via `rclone` (`../scripts/backup-prod.sh`).
Screenshots stay on local MinIO for now (not mirrored to S3) — revisit if
loss-of-screenshots-on-disk-failure becomes an acceptable risk to close.

---

# Production (AWS) — future target, not yet built

Once traffic/revenue justifies the cost (~$200-300/mo, see cost estimate in
project notes) and the reliability of a shared personal server is no longer
acceptable, migrate here. Will be codified with Terraform. Target shape
(subject to change):

- **Compute**: ECS Fargate (or EKS) — api service (≥2 tasks), worker service, client service.
- **Ingress**: ALB → api/client target groups; sticky sessions on the socket.io
  target group; ACM-managed TLS.
- **Data**: RDS Postgres (Multi-AZ), ElastiCache Redis, S3 for screenshots
  (replaces MinIO — `S3_FORCE_PATH_STYLE=false`).
- **Realtime**: `@socket.io/redis-adapter` backed by ElastiCache (same
  requirement proven in staging).
- **Secrets**: AWS Secrets Manager / SSM Parameter Store (no `.env` on hosts).
- **Migrations**: expand → migrate → contract, run as a one-off ECS task before
  the service update (same `lets-track-db-migrate` image used in staging).
- **CI/CD**: build + push to GHCR (or ECR), then `terraform apply` / service
  update with rolling deployment + health-gated rollback.

The rollout discipline mirrors staging: additive migrations first, one task
replaced at a time behind health checks, worker drains on SIGTERM.
