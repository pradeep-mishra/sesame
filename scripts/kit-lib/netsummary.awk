# netsummary.awk: the merge of the two network observers for `kit-net.sh summary` (verify.md S8.7; guesses K25, K26).
# A BEGIN-only program: it reads every input itself, prints the summary and ends with the exit status the script returns
# (0 clean, 1 a product failure, 4 the run is not valid). It reads no argument file.
#
# Variables (awk -v):
#   nettop    the nettop log as `kit-net.sh stop` leaves it (run/net/<name>.scoped.csv): `<time>,<name>.<pid>,...` process
#             rows (bytes_in is field 5, bytes_out field 6; bytes are totals since the process started, so the largest
#             value of a process is its total) and `<time>,tcp4 <local><-><peer>,<interface>,<state>,...` connection rows
#             under the process row above them (a Listen row is no connection). IPv4 spells host:port, IPv6 host.port.
#   trace     the fs_usage network trace as `kit-trace.sh start --net` leaves it (run/trace/<name>.net): `<time> <call>
#             <details> <seconds> [W] <process>.<thread>`; the thread is not a pid. The address is the detail field that
#             looks like an IP address followed by a port, spelled host.port or host:port. A line that holds the word
#             `dropped` is fs_usage's own report of lost events.
#   plants    run/net/<name>.plants: `PLANT <name> n=<k> pid=<pid> at=<epoch.ms> addr=127.0.0.1:<port>` lines.
#   requests  the mirror's request log: `<epoch.ms> <METHOD> <path> ...` per finished request ("" for none).
#   mirror    the mirror's address, host:port.
#   off       the local time zone's offset from UTC in seconds, at the day of the plants: both traces print the local time
#             of day, so the plants' and the mirror log's epochs are turned into the local time of day with it. A session
#             that crosses midnight is not handled (stated in the report).
#
# What is checked, and what it prints:
#   PLANT <k> seen-by fs_usage|nettop|both|none   every plant and which observer saw it. A plant is the process
#       SesameNetControl in the fs_usage trace (told by its port, within 3 s of its time) and the plant's pid in nettop
#       (told by pid and port). The fs_usage trace must show every plant, and no dropped events may be reported at a plant:
#       else `NOT VALID: ...` and exit 4 (a silent observer proves nothing). A drop line without a time counts at every plant.
#   PRODUCT <host:port> ...    a connection by a process named Sesame* (not a plant) to any address but the mirror's.
#   OUTSIDE ...                a product line before the mirror log's first request, or after its last, with 2 s of slack.
#   AFTER-LAST ...             a product connect after the last model request (nettop: a second later, it samples once a
#                              second), or any product connection when no request was logged.
#   BYTES <n> ...              1,000,000 bytes or more sent by processes named Sesame* (plants left out by pid).
#   Exit 4 wins over exit 1; the failure lines are printed either way.

function abs(x) { return x < 0 ? -x : x }

# "HH:MM:SS.ffffff" to seconds of the day; -1 when it is not a time.
function sod(t,   a, n) {
  if (t !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]/) return -1
  n = split(t, a, ":")
  if (n != 3) return -1
  return a[1] * 3600 + a[2] * 60 + a[3]
}

function sod_of_epoch(e,   w, s) {
  w = int(e)
  s = (w + off) % 86400
  if (s < 0) s += 86400
  return s + (e - w)
}

# "host:port" of a socket address spelled host:port or host.port (the port is what follows the last : or .), or "".
function addr_of(s,   i, c, host, port) {
  for (i = length(s); i >= 1; i--) {
    c = substr(s, i, 1)
    if (c == ":" || c == ".") break
  }
  if (i < 2) return ""
  host = substr(s, 1, i - 1)
  port = substr(s, i + 1)
  if (port !~ /^[0-9]+$/) return ""
  gsub("\\[", "", host)
  gsub("\\]", "", host)
  if (host == "localhost") host = "127.0.0.1"
  return host ":" port
}

function port_of(a,   i) {
  i = length(a)
  while (i > 1 && substr(a, i, 1) != ":") i--
  return substr(a, i + 1)
}

# A detail field of an fs_usage line that is an IP address with a port.
function ipish(tok) {
  if (tok ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[.:][0-9]+$/) return 1
  if (tok ~ /^\[?[0-9A-Fa-f:]*:[0-9A-Fa-f:%a-z]*\]?[.:][0-9]+$/ && addr_of(tok) != "") return 1
  return 0
}

function procname(s) {
  sub(/\.[0-9]+$/, "", s)
  return s
}

function plant_of_port(port,   j) {
  for (j = 1; j <= pn; j++) if (pport[j] == port) return j
  return 0
}

function plant_of_pid(pid,   j) {
  for (j = 1; j <= pn; j++) if (ppid[j] == pid) return j
  return 0
}

# Records one product connection or line for the checks at the end. kind: fs (a line of the fs_usage trace) or nt (nettop).
function product(kind, t, ts, proc, op, addr,   key) {
  key = kind "|" proc "|" op "|" addr "|" ts
  if (key in seen) return
  seen[key] = 1
  np++
  p_kind[np] = kind; p_t[np] = t; p_ts[np] = ts; p_proc[np] = proc; p_op[np] = op; p_addr[np] = addr
}

function bad(line) { print line; failed = 1 }
function invalid(line) { print "NOT VALID: " line; notvalid = 1 }

BEGIN {
  mirror_norm = addr_of(mirror)

  # ---- the plants ----
  while ((getline line < plants) > 0) {
    if (line !~ /^PLANT /) continue
    n = split(line, f, " ")
    k = ""; pid = ""; at = ""; pa = ""
    for (j = 1; j <= n; j++) {
      if (f[j] ~ /^n=/) k = substr(f[j], 3)
      else if (f[j] ~ /^pid=/) pid = substr(f[j], 5)
      else if (f[j] ~ /^at=/) at = substr(f[j], 4)
      else if (f[j] ~ /^addr=/) pa = addr_of(substr(f[j], 6))
    }
    if (k == "" || pid == "" || at == "" || pa == "") continue
    pn++
    pk[pn] = k; ppid[pn] = pid; pat[pn] = sod_of_epoch(at); pport[pn] = port_of(pa); paddr[pn] = pa
  }
  close(plants)

  # ---- the mirror's window ----
  while ((getline line < requests) > 0) {
    split(line, f, " ")
    if (f[1] !~ /^[0-9]+(\.[0-9]+)?$/) continue
    nreq++
    if (nreq == 1 || f[1] + 0 < first_e) first_e = f[1] + 0
    if (nreq == 1 || f[1] + 0 > last_e) last_e = f[1] + 0
  }
  close(requests)
  if (nreq > 0) {
    first_s = sod_of_epoch(first_e)
    last_s = sod_of_epoch(last_e)
    print "WINDOW the mirror's requests run from " first_s " to " last_s " (seconds of the day, " nreq " requests); mirror " mirror_norm
  } else {
    print "WINDOW no model request was logged; mirror " mirror_norm
  }

  # ---- the fs_usage network trace ----
  while ((getline line < trace) > 0) {
    nf = split(line, f, " ")
    if (tolower(line) ~ /dropped/) {
      nd++
      d_t[nd] = (nf >= 1 ? sod(f[1]) : -1)
      d_line[nd] = line
      continue
    }
    if (nf < 4 || sod(f[1]) < 0) continue
    proc = procname(f[nf])
    if (proc !~ /^Sesame/) continue
    saw_sesame++
    op = f[2]
    if (op !~ /^(connect|sendto|sendmsg)/) continue
    d = nf - 1
    if (f[d] == "W") d = nf - 2
    a = ""
    for (i = 3; i < d; i++) if (ipish(f[i])) { a = addr_of(f[i]); break }
    ne++
    e_t[ne] = sod(f[1]); e_ts[ne] = f[1]; e_proc[ne] = proc; e_op[ne] = op; e_addr[ne] = a
  }
  close(trace)

  for (i = 1; i <= ne; i++) {
    plantline = 0
    if (e_proc[i] == "SesameNetControl") {
      if (e_addr[i] != "") {
        j = plant_of_port(port_of(e_addr[i]))
        if (j && abs(e_t[i] - pat[j]) <= 3) { seen_trace[j] = 1; plantline = 1 }
      } else {
        for (j = 1; j <= pn; j++) if (abs(e_t[i] - pat[j]) <= 3) plantline = 1
      }
    }
    if (!plantline) product("fs", e_t[i], e_ts[i], e_proc[i], e_op[i], e_addr[i])
  }

  # ---- the nettop log ----
  while ((getline line < nettop) > 0) {
    nc = split(line, c, ",")
    if (c[1] == "time" || nc < 2) continue
    t = sod(c[1])
    if (t < 0) continue
    if (c[2] ~ /^(tcp|udp)[46]? /) {
      if (cname == "" || cname !~ /^Sesame/) continue
      if (c[4] == "Listen") continue
      body = substr(c[2], index(c[2], " ") + 1)
      k = index(body, "<->")
      if (k == 0) continue
      la = addr_of(substr(body, 1, k - 1))
      pa = addr_of(substr(body, k + 3))
      if (pa == "") continue
      j = plant_of_pid(cpid)
      if (j && (port_of(la) == pport[j] || port_of(pa) == pport[j])) {
        if (abs(t - pat[j]) <= 3) seen_nettop[j] = 1
        continue
      }
      key = cname "|" cpid "|" la "|" pa
      if (!(key in nt_first) || t < nt_first[key]) { nt_first[key] = t; nt_ts[key] = c[1] }
      nt_proc[key] = cname; nt_peer[key] = pa
    } else {
      name = c[2]
      cpid = ""
      if (match(name, /\.[0-9]+$/)) { cpid = substr(name, RSTART + 1); name = substr(name, 1, RSTART - 1) }
      cname = name
      if (name ~ /^Sesame/ && !plant_of_pid(cpid)) {
        sent = c[6] + 0
        if (!(cpid in nt_sent) || sent > nt_sent[cpid]) nt_sent[cpid] = sent
      }
    }
  }
  close(nettop)
  for (key in nt_first) product("nt", nt_first[key], nt_ts[key], nt_proc[key], "connection", nt_peer[key])

  # ---- the plants: which observer saw each ----
  for (j = 1; j <= pn; j++) {
    st = seen_trace[j] ? 1 : 0
    sn = seen_nettop[j] ? 1 : 0
    label = (st && sn) ? "both" : (st ? "fs_usage" : (sn ? "nettop" : "none"))
    print "PLANT " pk[j] " seen-by " label
    if (!st) invalid("plant " pk[j] " (pid " ppid[j] ", " paddr[j] ") was not seen by the fs_usage network trace: it cannot see a short connection, so its silence proves nothing; rerun")
  }
  if (saw_sesame == 0) invalid("the network trace holds no line of a process named Sesame*, so its positive control failed; rerun")
  for (i = 1; i <= nd; i++) {
    hit = 0
    for (j = 1; j <= pn; j++) {
      if (d_t[i] < 0 || abs(d_t[i] - pat[j]) <= 3) { invalid("the fs_usage trace reports dropped events during plant " pk[j] " (" d_line[i] "); rerun"); hit = 1 }
    }
    if (!hit) print "NOTE fs_usage reported dropped events away from every plant (" d_line[i] "): events lost there cannot be proven"
  }

  # ---- the product ----
  for (i = 1; i <= np; i++) {
    who = p_proc[i] " (" (p_kind[i] == "fs" ? "fs_usage " : "nettop ") p_ts[i] ")"
    if (p_addr[i] != "" && p_addr[i] != mirror_norm) {
      pkey = p_proc[i] "|" p_addr[i]
      if (!(pkey in said)) { said[pkey] = 1; bad("PRODUCT " p_addr[i] " by " who ": a destination other than the mirror") }
    }
    after_bar = (p_kind[i] == "nt") ? last_s + 1 : last_s
    # one line per process, call and address, however many times it repeats
    wkey = p_proc[i] "|" p_op[i] "|" p_addr[i]
    if (nreq == 0) {
      if ((p_kind[i] == "nt" || p_op[i] == "connect") && !(("A" wkey) in said)) {
        said["A" wkey] = 1
        bad("AFTER-LAST " who " " p_op[i] " " p_addr[i] ": no model request was logged, so this is a connection after the last model request")
      }
    } else if ((p_kind[i] == "nt" || p_op[i] == "connect") && p_t[i] > after_bar) {
      if (!(("A" wkey) in said)) {
        said["A" wkey] = 1
        bad("AFTER-LAST " who " " p_op[i] " " p_addr[i] ": a connection after the last model request")
      }
    } else if (p_t[i] < first_s - 2 || p_t[i] > last_s + 2) {
      if (!(("O" wkey) in said)) {
        said["O" wkey] = 1
        bad("OUTSIDE " who " " p_op[i] " " p_addr[i] ": outside the mirror's first-to-last request window plus 2 s")
      }
    }
  }
  for (pid in nt_sent) total += nt_sent[pid]
  total += 0
  print "SENT " total " bytes sent by processes named Sesame* (nettop, plants left out by pid)"
  if (total >= 1000000) bad("BYTES " total " sent by processes named Sesame*, the limit is 1,000,000")

  if (notvalid) exit 4
  if (failed) exit 1
  print "no connection after the last model request, none to another destination, under 1 MB sent: the product's network use is the mirror's and only inside its window"
  exit 0
}
