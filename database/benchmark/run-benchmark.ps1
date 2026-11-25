# GameOn performance benchmark: each key query BEFORE (its index disabled) and AFTER (index rebuilt).
# DISPOSABLE *_Tests DATABASE ONLY - it disables and rebuilds indexes.
#   powershell -ExecutionPolicy Bypass -File database\benchmark\run-benchmark.ps1 -Database GameOn_Tests -Out results.json
# Each query runs as a parameterised statement (sp_executesql, like the API), 1 warm-up + 7 timed runs; the median
# server elapsed time, logical reads (STATISTICS IO), rows returned and the plan's access operator are recorded.
param([string]$Database = "GameOn_Tests", [string]$Out = "benchmark-results.json", [int]$Runs = 7)
$ErrorActionPreference = "Stop"
if ($Database -notlike "*_Tests") { throw "Run only on a disposable *_Tests database." }
$cn = New-Object System.Data.SqlClient.SqlConnection "Server=localhost;Database=$Database;Integrated Security=true;TrustServerCertificate=true"
$cn.Open()
$global:GOmsgs = New-Object System.Collections.Generic.List[string]
$cn.add_InfoMessage({ param($s, $e) foreach ($er in $e.Errors) { $global:GOmsgs.Add($er.Message) } })
$cn.FireInfoMessageEventOnUserErrors = $false
function Exec([string]$sql) { $c = $cn.CreateCommand(); $c.CommandTimeout = 300; $c.CommandText = $sql; [void]$c.ExecuteNonQuery() }
function Scalar([string]$sql) { $c = $cn.CreateCommand(); $c.CommandText = $sql; $c.ExecuteScalar() }
Exec "SET QUOTED_IDENTIFIER ON; SET ANSI_NULLS ON; SET ARITHABORT ON;"

# Parameters taken from the data (the synthetic performance club and its busiest values)
$court = Scalar "SELECT TOP(1) c.CourtId FROM dbo.Courts c JOIN dbo.Clubs k ON k.ClubId=c.ClubId WHERE k.Name=N'GameOn Performance Lab (synthetic data)' ORDER BY c.CourtId"
$club = Scalar "SELECT ClubId FROM dbo.Courts WHERE CourtId=$court"
$user = Scalar "SELECT TOP(1) UserId FROM dbo.CourtBookings WHERE UserId IS NOT NULL GROUP BY UserId ORDER BY COUNT(*) DESC"
$game = Scalar "SELECT TOP(1) GameId FROM dbo.GameActivityLogs GROUP BY GameId ORDER BY COUNT(*) DESC"
$actor = Scalar "SELECT TOP(1) ActorUserId FROM dbo.GameActivityLogs WHERE ActorUserId IS NOT NULL GROUP BY ActorUserId ORDER BY COUNT(*) DESC"
$day = (Scalar "SELECT CONVERT(varchar(10),DATEADD(day,-30,CONVERT(date,SYSUTCDATETIME())),120)")
$from = (Scalar "SELECT CONVERT(varchar(10),DATEADD(month,-1,DATEFROMPARTS(YEAR(SYSUTCDATETIME()),MONTH(SYSUTCDATETIME()),1)),120)")

$queries = @(
 @{ id="Q1"; name="Court schedule for one day (GetCourtSchedule)"; table="CourtBookings"; index="IX_CB_Court_Time";
    sql="SELECT BookingId,StartsAt,EndsAt,Status FROM dbo.CourtBookings WHERE CourtId=@Court AND StartsAt>=@Day AND StartsAt<DATEADD(day,1,@Day)";
    params="@Court int,@Day datetime2(3)"; args="@Court=$court,@Day='$day'" },
 @{ id="Q2"; name="A player's last 20 bookings (MyCourtBookings)"; table="CourtBookings"; index="IX_CB_User";
    sql="SELECT TOP(20) BookingId,CourtId,StartsAt,Status FROM dbo.CourtBookings WHERE UserId=@User ORDER BY StartsAt DESC";
    params="@User int"; args="@User=$user" },
 @{ id="Q3"; name="Club revenue for one month (club dashboard)"; table="CourtBookings"; index="IX_CB_Court_Time";
    sql="SELECT SUM(b.Price) AS Revenue,COUNT(*) AS Bookings FROM dbo.Courts c JOIN dbo.CourtBookings b ON b.CourtId=c.CourtId WHERE c.ClubId=@Club AND b.StartsAt>=@From AND b.StartsAt<DATEADD(month,1,@From) AND b.Status IN('Completed','NoShow')";
    params="@Club int,@From datetime2(3)"; args="@Club=$club,@From='$from'" },
 @{ id="Q4"; name="Bookings per day for one month (AdminAnalytics)"; table="CourtBookings"; index="IX_CB_Start";
    sql="SELECT CONVERT(date,StartsAt) AS Day,COUNT(*) AS Bookings,SUM(Price) AS Value FROM dbo.CourtBookings WHERE StartsAt>=@From AND StartsAt<DATEADD(month,1,@From) AND Status IN('Confirmed','Completed','NoShow') GROUP BY CONVERT(date,StartsAt)";
    params="@From datetime2(3)"; args="@From='$from'" },
 @{ id="Q5"; name="Double-booking check for one slot (BookCourt)"; table="CourtBookings"; index="UX_CB_Slot";
    sql="SELECT COUNT(*) FROM dbo.CourtBookings WHERE CourtId=@Court AND StartsAt=@Day AND Status IN('Pending','Confirmed','Completed','NoShow')";
    params="@Court int,@Day datetime2(3)"; args="@Court=$court,@Day='$day'" },
 @{ id="Q6"; name="History of one game (GetGameActivity)"; table="GameActivityLogs"; index="IX_Activity_Game_Time";
    sql="SELECT TOP(50) ActivityId,ActorUserId,ActivityType,OccurredAt FROM dbo.GameActivityLogs WHERE GameId=@Game ORDER BY OccurredAt DESC";
    params="@Game int"; args="@Game=$game" },
 @{ id="Q7"; name="Activity of one user (admin review)"; table="GameActivityLogs"; index="IX_Activity_User_Time";
    sql="SELECT TOP(50) ActivityId,GameId,ActivityType,OccurredAt FROM dbo.GameActivityLogs WHERE ActorUserId=@Actor ORDER BY OccurredAt DESC";
    params="@Actor int"; args="@Actor=$actor" }
)

function Invoke-QueryMeasure($q, [switch]$FullScan) {
  $sql = $q.sql
  # Full scan = the same query forced to read the whole table (clustered index) - the "no index" baseline.
  if ($FullScan) { $sql = [regex]::Replace($sql, "dbo\.$($q.table)( b)?", { param($m) $m.Value + " WITH(INDEX(1))" }) }
  $stmt = "EXEC sp_executesql N'" + $sql.Replace("'", "''") + "',N'" + $q.params + "'," + $q.args
  Exec "DBCC FREEPROCCACHE WITH NO_INFOMSGS;"
  # Plan (actual) once
  $c = $cn.CreateCommand(); $c.CommandText = "SET STATISTICS XML ON; $stmt; SET STATISTICS XML OFF;"
  $r = $c.ExecuteReader(); $rows = 0; $planXml = $null
  do { while ($r.Read()) { if ($r.FieldCount -eq 1 -and $r.GetName(0) -like "Microsoft SQL Server*XML*") { $planXml = $r.GetString(0) } else { $rows++ } } } while ($r.NextResult()); $r.Close()
  $ops = @()
  if ($planXml) { [xml]$x = $planXml; $ns = New-Object Xml.XmlNamespaceManager($x.NameTable); $ns.AddNamespace("p", "http://schemas.microsoft.com/sqlserver/2004/07/showplan")
    foreach ($ro in $x.SelectNodes("//p:RelOp", $ns)) { $o = $ro.SelectSingleNode("./*/p:Object", $ns); if ($o -and $o.Table -eq "[$($q.table)]") { $ops += "$($ro.PhysicalOp) $($o.Index)".Trim() } } }
  # Timed runs
  [void](Exec $stmt)
  $times = @(); $reads = 0
  for ($i = 0; $i -lt $Runs; $i++) {
    $global:GOmsgs.Clear()
    Exec "SET STATISTICS IO ON; SET STATISTICS TIME ON; $stmt; SET STATISTICS TIME OFF; SET STATISTICS IO OFF;"
    $all = $global:GOmsgs -join "`n"
    $m = [regex]::Matches($all, "elapsed time = (\d+) ms"); if ($m.Count) { $times += [int]$m[$m.Count - 1].Groups[1].Value }
    $rm = [regex]::Match($all, "Table '$($q.table)'\. Scan count \d+, logical reads (\d+)"); if ($rm.Success) { $reads = [int]$rm.Groups[1].Value }
  }
  $sorted = @($times | Sort-Object); if ($sorted.Count -eq 0) { throw "No timing captured for $($q.id)" }
  [pscustomobject]@{ ms = $sorted[[int][math]::Floor($sorted.Count / 2)]; reads = $reads; rows = $rows; plan = ($ops | Select-Object -Unique) -join " + " }
}

$results = @()
foreach ($q in $queries) {
  Exec "ALTER INDEX [$($q.index)] ON dbo.[$($q.table)] DISABLE;"
  try { $before = Invoke-QueryMeasure $q } finally { Exec "ALTER INDEX [$($q.index)] ON dbo.[$($q.table)] REBUILD;" }
  $after = Invoke-QueryMeasure $q
  $scan = Invoke-QueryMeasure $q -FullScan
  $results += [pscustomobject]@{ id = $q.id; name = $q.name; table = $q.table; index = $q.index; sql = $q.sql; fullScan = $scan; before = $before; after = $after }
  "{0}  scan {1} ms/{2} reads | index off {3} ms/{4} reads [{5}] | index on {6} ms/{7} reads [{8}]" -f $q.id, $scan.ms, $scan.reads, $before.ms, $before.reads, $before.plan, $after.ms, $after.reads, $after.plan
}
$rowsCB = Scalar "SELECT COUNT_BIG(*) FROM dbo.CourtBookings"; $rowsGL = Scalar "SELECT COUNT_BIG(*) FROM dbo.GameActivityLogs"
[pscustomobject]@{ database = $Database; runAt = (Get-Date).ToString("s"); runs = $Runs; courtBookingsRows = $rowsCB; gameActivityLogsRows = $rowsGL;
  server = (Scalar "SELECT @@VERSION").Split("`n")[0]; results = $results } | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 $Out
$cn.Close(); "saved $Out"
