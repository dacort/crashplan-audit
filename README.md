# Crashplan Audit
A small utility to verify local files have been backed up by Crashplan. Currently only tested on OS X.

## Background
Back in March of 2016, I discovered that Crashplan was [not backing up](https://twitter.com/dacort/status/705116204956954625) some of my files. Given that I have a tendency to wipe my machine every 6 months, this was a disturbing discovery.

Curious as to just how bad the issue was, I set out to put together a script to evaluate current filesystem status against my Crashplan archive.

For context, Crashplan is backing up just under 2M files and 300GB.

Crashplan has a [fairly robust api](https://www.crashplan.com/apidocviewer/), but it took quite a while to figure out the magic incantation of login tokens, data keys, and magical destination guids.

Even so, after a certain number of API requests, the script will fail with a non-descript `SYSTEM` error that I assume is related to a token expiring. Restarting the script continues the process.

## Usage

The script is pretty straight-forward. There's a `TEST_DIR` variable defined at the top of [treenode.rb](treenode.rb) that is the directory you want to evaluate. It defaults to `$HOME`.

There are also two variables, `IGNORE` and `IGNORE_DIRS` that are intended to bypass common directories that are both non-critical and easily reproducible. For example, `node_modules` in npm projects.

To get started:
  - Make sure you have the necessary gems: `bundle install`
  - Run the script! `bundle exec ruby treenode.rb`

The script will ask you for your Crashplan username and password. It also assumes you are using an additional passphrase to protect your archive and will ask you for that as well.

The script will start in `TEST_DIR` and log the status of all directories and files to a sqlite3 database: `cpaudit.db`.

As mentioned above, the API will return some SYSTEM error at some point and crash the script. I have yet to add proper handling for this, but restarting the script will continue the process and skip over directories that have already been verified.

Depending on the number of files, the script will take many hours to run as it has to continuously retrieve directory and file status from the Crashplan API. As an example, I limited my run to a directory with just over 1M files and I had to run the script overnight in a while loop in bash to accommodate for the errors returned by the Crashplan API. 😬

## Review

Once the script is finished, you'll be able to examine the sqlite database to identify missing files or directories.

1. Open the sqlite database
```sh
sqlite3 cpaudit.db
```

2. Count the number of missing files
```sql
SELECT COUNT(*)
FROM (
    SELECT path, status_id, max(inserted_at)
    FROM file_audit
    GROUP BY path
)
WHERE status_id = 1;
```

3. List the actual missing files
```sql
SELECT *
FROM (
    SELECT path, status_id, max(inserted_at)
    FROM file_audit
    GROUP BY path
)
WHERE status_id = 1;
```
