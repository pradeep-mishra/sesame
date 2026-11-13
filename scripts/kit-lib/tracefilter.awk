# tracefilter.awk: reads `fs_usage -w` lines and prints the ones a kit-trace.sh mode asks for.
# A line that holds the word `dropped` is fs_usage's own report of lost events, not a process line: it is skipped here
# (kit-net.sh summary reads it from the network trace).
# Variables: mode (opens | writes | net | procs), by (a process name; a trailing * means "starts with"; opens, writes and net),
#            under and under2 (the folder, as given and as its real path; a path is under it when it is the
#            folder or starts with the folder and a slash).
# An fs_usage line is: <time> <operation> <details...> <seconds> [W] <process>.<thread>. The path is the
# first field that starts with a slash; a path with a space in it is rejoined up to the seconds field.
# Output, tab separated: opens and writes `<process> <operation> <path>`; net `<time> <operation> <process>
# <what the call went to>`; procs `<process>`.

function procname(s,   n) {
  n = s
  sub(/\.[0-9]+$/, "", n)
  return n
}

function under_ok(p) {
  if (under != "" && (p == under || index(p, under "/") == 1)) return 1
  if (under2 != "" && (p == under2 || index(p, under2 "/") == 1)) return 1
  return 0
}

function by_ok(n,   m) {
  if (by == "") return 1
  m = length(by)
  if (substr(by, m, 1) == "*") return index(n, substr(by, 1, m - 1)) == 1
  return n == by
}

{
  if (NF < 4) next
  if (tolower($0) ~ /dropped/) next
  if ($1 !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) next
  op = $2
  proc = procname($NF)
  d = NF - 1
  if ($d == "W") d = NF - 2
  p = 0
  for (i = 3; i < d; i++) if (substr($i, 1, 1) == "/") { p = i; break }
  path = ""
  if (p) for (i = p; i < d; i++) path = path (i == p ? "" : " ") $i
  rest = ""
  for (i = 3; i < d; i++) rest = rest (i == 3 ? "" : " ") $i

  if (mode == "procs") {
    print proc
  } else if (mode == "opens") {
    if ((index(op, "open") == 1 || index(op, "guarded_open") == 1) && path != "" && by_ok(proc) && under_ok(path))
      print proc "\t" op "\t" path
  } else if (mode == "writes") {
    iswrite = 0
    if (op ~ /^(WrData|WrMeta|write|pwrite|writev|pwritev|unlink|rename|renameat|mkdir|mkdirat|rmdir|truncate|ftruncate|chmod|fchmod|chown|fchown|utimes|futimes|setxattr|fsetxattr|removexattr|symlink|link|clonefile|exchangedata|setattrlist|fsetattrlist)/) iswrite = 1
    if (index(op, "open") == 1 || index(op, "guarded_open") == 1) {
      for (i = 3; i < d; i++) if ($i ~ /^\(.W/) iswrite = 1
    }
    # A write line can name a device first and the file after it: try the path from each slash field on.
    if (iswrite && by_ok(proc)) {
      for (q = 3; q < d; q++) {
        if (substr($q, 1, 1) != "/") continue
        cand = ""
        for (i = q; i < d; i++) cand = cand (i == q ? "" : " ") $i
        if (under_ok(cand)) { print proc "\t" op "\t" cand; break }
      }
    }
  } else if (mode == "net") {
    if (op ~ /^(connect|sendto|sendmsg)/ && by_ok(proc))
      print $1 "\t" op "\t" proc "\t" rest
  }
}
