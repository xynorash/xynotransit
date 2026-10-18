# Example data

A fresh database has an empty catalog: the first manager comes from `BOOTSTRAP_CONTROLLER_EMAIL` and builds teams, people and seats in the app.

These files are only for trying the system with data. They are not loaded automatically.

| File | Content |
| --- | --- |
| `10-seed.sql` | The original catalog: 4 teams, 13 people, their seats, counts and targets. Placeholder emails. |
| `20-seed-demo.sql` | 14 demo reports for Feb 2026. Needs `10-seed.sql` first. |

Load them into a running, empty database (the catalog tables must be empty, or the inserts fail on duplicates):

```bash
cd xynotransit-db
docker exec -i xynotransit-db-db-1 psql -v ON_ERROR_STOP=1 -U xynotransit -d xynotransit -f - < examples/10-seed.sql
docker exec -i xynotransit-db-db-1 psql -v ON_ERROR_STOP=1 -U xynotransit -d xynotransit -f - < examples/20-seed-demo.sql
```

The seed inserts a person for `shalini@xynotransit.example`. If the API already created that person from `BOOTSTRAP_CONTROLLER_EMAIL`, delete it first (`delete from person where email = 'shalini@xynotransit.example'`) or the insert fails on the duplicate email. The API promotes an existing person with the bootstrap email, so loading the seed first and starting the API after also works.
