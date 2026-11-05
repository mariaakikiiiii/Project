# Non-executable migration templates

Do not execute these `.sql.txt` files in SSMS. They preserve module definitions
used by `../build-safe-migrations.py`; their original multi-batch headers are
historical and unsafe for ordinary SSMS execution.

Run the generated files in `database/` instead. To regenerate the current
ordinary-SSMS version 16/18 files and the guarded 13/16 repair:

```sh
python3 scripts/build-safe-migrations.py
```

No runtime input is inserted into the generated DDL strings. Each constant DDL
statement/module is compiled separately inside one outer transaction, avoiding
SQL Server's same-batch column binding error. Validate both the wrappers and
embedded constant SQL using the database check tool's `--syntax` mode.
