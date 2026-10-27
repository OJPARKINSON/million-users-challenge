# Hetzner test boxes

Builds a copy of the challenge's setup on Hetzner Cloud for a test session, then deletes it:
`app` (ccx43, your server), `db` (Postgres + seed) and `lg1` (the load generator), on a private network, with
SSH open only to your IP. About €1/hour while it runs; nothing is billed after `tofu destroy`.

**Needs:** [OpenTofu](https://opentofu.org), the [1Password CLI](https://developer.1password.com/docs/cli) (or plain
values in `.env`), a Hetzner Cloud API token, and an SSH public key saved at `~/.ssh/hetzner.pub` (or set `KEY=`).
New Hetzner accounts have low vCPU limits (Console → Limits): this needs 16 dedicated + 24 shared vCPUs.

```bash
cp infra/.env.example infra/.env                       # then fill it in
cd infra && tofu init
op run --env-file=.env -- tofu apply                   # create the boxes
bash up.sh                                             # set them up, run the 42 checks (5-10 min); or: bash up.sh examples/rust
```

**Load test** (on lg1, the command `up.sh` prints at the end):

```bash
ssh -i ~/.ssh/hetzner.pub -o IdentitiesOnly=yes root@$(tofu output -raw lg1_ip)
cd repo && ulimit -n 1048576
./bench/mload/mload -target 10.0.0.2,10.0.0.3,10.0.0.4,10.0.0.5 -ports 80,81 -users 100000 -ramp 60s -hold 2m \
  -gzip -think-scale 2.5 -tokens seed/tokens.json -out run.json
```

**Between runs** (from `infra/`): a fresh database, then restart your server and wait until it's healthy.

```bash
ssh -i ~/.ssh/hetzner.pub -o IdentitiesOnly=yes root@$(tofu output -raw db_ip) 'bash repo/box/reset-db.sh'
ssh -i ~/.ssh/hetzner.pub -o IdentitiesOnly=yes root@$(tofu output -raw app_ip) \
  'systemctl restart challenge; until curl -fs localhost/health >/dev/null; do sleep 1; done; echo ready'
```

**When you're done:** copy `run.json` off lg1, then `op run --env-file=.env -- tofu destroy`.
Powered-off servers are still billed, so always destroy.

**Not the same as the scored boxes:**

- **App box memory:** a ccx43 has 64 GB, but the challenge box has 32 GB.
- **Database box CPUs:** `db` uses shared vCPUs until your dedicated-vCPU limit is raised.
- **Load generator ceiling:** one 8-vCPU load generator tops out at about 250k users. Past that, add `lg2`, ... in
  `main.tf` and split users with `-offset` and `-start` (see [bench/README.md](../bench/README.md)).
