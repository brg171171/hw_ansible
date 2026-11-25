# Inspect exactly the three expected rows in Ansible's default PLAY RECAP.
BEGIN { expected["ch01"]; expected["vec01"]; expected["lh01"] }
/^PLAY RECAP / { recap++; next }
recap && NF && $2 == ":" {
  if (!($1 in expected) || ++seen[$1] != 1) bad=1
  delete value
  for (i=3; i<=NF; i++) {
    split($i, kv, "=")
    if (kv[2] ~ /^[0-9]+$/) value[kv[1]]=kv[2]+0
  }
  if (!("ok" in value) || !value["ok"] || !("changed" in value) ||
      !("failed" in value) || value["failed"] || !("unreachable" in value) ||
      value["unreachable"] || (stable && value["changed"])) bad=1
  print
}
END {
  for (host in expected) if (seen[host] != 1) bad=1
  if (recap != 1 || bad) {
    print "Некорректный PLAY RECAP: проверьте полный лог." > "/dev/stderr"
    exit 1
  }
}
