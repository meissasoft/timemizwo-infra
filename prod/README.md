# Production (AWS) — placeholder

Staging (`../staging`) is the current focus. Production on AWS will be codified
with Terraform here later. Target shape (subject to change):

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
