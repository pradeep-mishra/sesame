# loadstat.awk: reads the output of `top -l 2 -s 1 -n <n> -o cpu -stats pid,command,cpu` (kit-load.sh measure)
# and prints "<system> <skipped>" for the LAST sample, the one measured over the one-second interval:
#   system   whole-system CPU in percent of all cores (user plus sys of the "CPU usage:" line)
#   skipped  the summed %CPU (percent of one core, so it may pass 100) of every listed process whose
#            command starts with the awk variable `skip` (kit-load.sh passes the Sesame name prefix)
# Exit 1, printing nothing, when the text holds no "CPU usage:" line.
/^Processes:/ { sys = 0; got = 0; sk = 0; rows = 0; next }
/^CPU usage:/ { u = $3; s = $5; sub(/%/, "", u); sub(/%/, "", s); sys = u + s; got = 1; next }
/^PID[ \t]/ { rows = 1; next }
rows && NF >= 3 && $1 ~ /^[0-9]+$/ { if (index($2, skip) == 1) sk += $NF; next }
END { if (!got) exit 1; printf "%.1f %.1f\n", sys, sk }
