# Automating the Bronze Refresh

## Why this is needed

The Snowflake trial account can't create an External Access Integration, so Snowflake itself has no way to reach out and pull fresh data from Postgres on a schedule — that's why Bronze ingestion has been a manual step (`psql` export → SnowSQL `PUT` → `COPY INTO`) since Phase 4 started. That limitation only blocks automation *from inside* Snowflake, though. It doesn't stop something outside Snowflake — a script on a schedule — from running the exact same steps you've been running by hand.

`refresh_bronze_from_postgres.sh` + `36_copy_into_bronze.sql` do that: export the 4 raw tables, `PUT` them to `@BRONZE.RAW_LANDING`, load them into Bronze, and print row counts to confirm the load worked. Once Bronze is current, the existing `TASK_REFRESH_SILVER_REAL` → `TASK_EXPORT_REPORTS_REAL` DAG (file 18) already runs automatically every day at 9am and brings Silver/Gold/Reports current — so scheduling just this one script closes the last manual gap.

## One-time setup

1. Confirm `psql` and `snowsql` are on your `PATH` (already installed per the original manual load).
2. Set up a named SnowSQL connection so the script never needs a plaintext Snowflake password:
   ```
   # ~/.snowsql/config
   [connections.sales_analytics]
   accountname = <your_account>
   username = <your_user>
   authenticator = externalbrowser   # or your usual auth method
   dbname = SALES_ANALYTICS
   warehousename = SALES_ANALYTICS_WH
   ```
3. Set up Postgres credentials via a `.pgpass` file (`~/.pgpass`, mode `600`) rather than env vars in the script:
   ```
   your_pg_host:5432:your_db:your_user:your_password
   ```
4. Make the script executable:
   ```
   chmod +x refresh_bronze_from_postgres.sh
   ```
5. Run it once manually to confirm it works end to end before scheduling it:
   ```
   ./refresh_bronze_from_postgres.sh
   ```

## Scheduling — pick one

### Option A: cron (Mac/Linux, simplest — recommended if a machine is reliably on)

```
crontab -e
```
Add a line to run daily at 7:45am (15 min after the source's stated 7:30am EST refresh):
```
45 7 * * * PGHOST=... PGUSER=... /full/path/to/refresh_bronze_from_postgres.sh >> ~/sales_analytics_bronze_refresh.log 2>&1
```
Cron runs with a minimal environment, so either export Postgres connection details in the crontab line itself (as above) or source a `.env` file at the top of the script. `.pgpass` and `~/.snowsql/config` are both picked up automatically without extra flags.

### Option B: macOS `launchd` (more reliable than cron on a laptop that sleeps)

Create `~/Library/LaunchAgents/com.salesanalytics.bronzerefresh.plist` with a `StartCalendarInterval` of `Hour: 7, Minute: 45`, `ProgramArguments` pointing at the script, then:
```
launchctl load ~/Library/LaunchAgents/com.salesanalytics.bronzerefresh.plist
```
`launchd` will also run the job on wake if the scheduled time was missed while the machine was asleep — cron won't.

### Option C: Windows Task Scheduler

Task Scheduler → Create Task → Trigger: Daily, 7:45 AM → Action: Start a program → point at `bash.exe` (WSL) or a `.bat` wrapper calling the script → check "Run whether user is logged on or not."

### Option D: Cloud-hosted (no local machine required)

If you'd rather not depend on a laptop being on, a scheduled GitHub Actions workflow or a small AWS Lambda + EventBridge schedule can run the same script. The trade-off: Postgres and Snowflake credentials then need to live as encrypted secrets in that platform instead of on your machine — worth it only if uptime matters more than keeping credentials local.

## After scheduling

- Check `~/sales_analytics_bronze_refresh.log` (or wherever `LOGFILE` points) after the first few scheduled runs to confirm rows are actually landing, not just that the script exits 0.
- The stage purge (`21_bronze_purge_real_data.sql`) is deliberately still a manual step — run it periodically once you've confirmed a run's `COPY INTO` succeeded, so `@BRONZE.RAW_LANDING` doesn't grow unbounded.
- Once this has run cleanly a few times, the "no data past 2026-08-18" gap goes away on its own — no code change needed downstream, since Silver/Gold/Reports already refresh automatically once Bronze is current.
