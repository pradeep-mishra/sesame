# schemawords.awk: the word-splitter of `kit-privacy.sh schema-scan` (S8.9). Reads table and column names, one per
# line, and prints `forbidden: <name>` or `allowed: <name>` for each. A name is split into words at underscores and at
# lower-to-upper changes (lastOpened is last, opened); it is forbidden when one word is a tracking word (the first list
# below), or when a word is count or counts and no other word says what is counted (the second list: a page count, a
# chunk count and a frame count describe a file, a bare count could be a use count). The words are written by hand from
# the spec; run it as: LC_ALL=C awk -f schemawords.awk
BEGIN {
  n = split("query queries history recent open opens opened hit hits visits usage popularity boost", f, " ")
  for (i = 1; i <= n; i++) bad[f[i]] = 1
  n = split("page pages line lines chunk chunks passage passages frame frames window", f, " ")
  for (i = 1; i <= n; i++) counted[f[i]] = 1
}
NF == 0 { next }
{
  name = $0
  s = ""; p = ""
  for (i = 1; i <= length(name); i++) {
    c = substr(name, i, 1)
    if (c ~ /[A-Z]/ && p ~ /[a-z]/) s = s " "
    s = s c
    p = c
  }
  gsub(/[_ ]+/, " ", s)
  s = tolower(s)
  n = split(s, w, " ")
  isbad = 0; hascount = 0; hascounted = 0
  for (i = 1; i <= n; i++) {
    if (w[i] in bad) isbad = 1
    if (w[i] == "count" || w[i] == "counts") hascount = 1
    if (w[i] in counted) hascounted = 1
  }
  if (hascount && !hascounted) isbad = 1
  print (isbad ? "forbidden: " : "allowed: ") name
}
