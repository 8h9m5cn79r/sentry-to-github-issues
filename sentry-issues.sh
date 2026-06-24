#!/usr/bin/env bash
#
# Poll Sentry for newly-detected issues and open a matching GitHub issue for
# each one. Driven entirely by environment variables (see action.yml).
#
# Safe to run on a schedule: dedup is by a hidden "sentry-id: <short-id>" marker
# in the body of every issue we file. Before filing we read back the short-ids
# of all label-tagged issues (open AND closed) and skip any already filed — so a
# given Sentry issue is filed exactly once, even after its GitHub issue closes.
#
# Each filed issue embeds the most recent event's stack trace (fetched from the
# events/latest API) in a collapsed <details> block. Best-effort: if the trace
# can't be fetched/parsed the issue is still filed, just without the block.
set -euo pipefail

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "::warning::SENTRY_AUTH_TOKEN is not set — nothing to do."
  exit 0
fi

: "${SENTRY_HOST:=https://sentry.io}"
: "${SENTRY_QUERY:=is:unresolved}"
: "${LOOKBACK_HOURS:=24}"
: "${MAX_PER_RUN:=25}"
: "${ISSUE_LABEL:=sentry}"

# The label must exist before `gh issue create --label` will accept it, and the
# dedup read filters on it. Create it once; ignore "already exists".
gh label create "$ISSUE_LABEL" --repo "$GH_REPO" \
  --color FF6B6B --description "Auto-filed from Sentry" 2>/dev/null || true

cutoff=$(date -u -d "${LOOKBACK_HOURS} hours ago" +%s)
echo "Filing issues first seen on/after $(date -u -d "@${cutoff}" '+%Y-%m-%d %H:%M UTC')"

# Short-ids we've already filed (open + closed), so we never duplicate.
seen="$(mktemp)"
gh issue list --repo "$GH_REPO" --label "$ISSUE_LABEL" --state all --limit 1000 \
  --json body --jq '.[].body' 2>/dev/null \
  | grep -oE 'sentry-id: [^ <]+' | awk '{print $2}' | sort -u > "$seen" || true
echo "Already filed: $(wc -l < "$seen" | tr -d ' ') Sentry issue(s)."

# jq program that distils a Sentry event into a compact stack trace. Prefers the
# crashed/current thread (right for App Hang/ANR, where the main thread stalled),
# falling back to the exception's own stacktrace. Frames arrive oldest-first, so
# reverse to put the offending frame on top; cap at 30. In-app frames get "* ".
read -r -d '' TRACE_JQ <<'JQ' || true
def fmtframe:
  (if (.inApp // false) then "* " else "  " end)
  + (.function // .symbol // "<unknown>")
  + (if .filename then " (" + .filename + (if .lineNo then ":" + (.lineNo|tostring) else "" end) + ")"
     elif .package then " [" + (.package | sub(".*/";"")) + "]"
     else "" end);
( [ .entries[]? | select(.type=="threads") | .data.values[]?
    | select((.crashed // false) or (.current // false))
    | .stacktrace.frames ] | map(select(. != null)) | .[0] ) as $tf
| ( [ .entries[]? | select(.type=="exception") | .data.values[]?
    | .stacktrace.frames ] | map(select(. != null)) | .[0] ) as $ef
| ( ($tf // $ef) // [] )
| reverse | .[0:30] | map(fmtframe) | join("\n")
JQ

filed=0
for project in $SENTRY_PROJECTS; do
  q=$(jq -rn --arg q "$SENTRY_QUERY" '$q | @uri')
  url="${SENTRY_HOST}/api/0/projects/${SENTRY_ORG}/${project}/issues/?query=${q}&sort=new&limit=50"

  resp=$(curl -fsS -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" "$url") || {
    echo "::warning::Sentry API request failed for project '${project}' — skipping."
    continue
  }

  while read -r issue; do
    [ -z "$issue" ] && continue
    shortId=$(jq -r '.shortId // empty' <<<"$issue")
    [ -z "$shortId" ] && continue

    # Already filed?
    if grep -qxF "$shortId" "$seen"; then
      continue
    fi

    firstSeen=$(jq -r '.firstSeen // empty' <<<"$issue")
    fsEpoch=$(date -u -d "$firstSeen" +%s 2>/dev/null || echo 0)
    if [ "$fsEpoch" -lt "$cutoff" ]; then
      continue
    fi

    if [ "$filed" -ge "$MAX_PER_RUN" ]; then
      echo "::warning::Hit MAX_PER_RUN=${MAX_PER_RUN}; remaining new issues will be filed next run."
      break 2
    fi

    title=$(jq -r '.title // .metadata.value // .culprit // "Unknown error"' <<<"$issue")
    level=$(jq -r '.level // "error"' <<<"$issue")
    count=$(jq -r '.count // "?"' <<<"$issue")
    lastSeen=$(jq -r '.lastSeen // "?"' <<<"$issue")
    permalink=$(jq -r '.permalink // empty' <<<"$issue")

    # Fetch the most recent event so the issue carries a real stack trace.
    # Pure best-effort: a failed request or empty result just files without it.
    issueId=$(jq -r '.id // empty' <<<"$issue")
    trace=""
    if [ -n "$issueId" ]; then
      ev=$(curl -fsS -H "Authorization: Bearer ${SENTRY_AUTH_TOKEN}" \
            "${SENTRY_HOST}/api/0/organizations/${SENTRY_ORG}/issues/${issueId}/events/latest/" 2>/dev/null) || ev=""
      [ -n "$ev" ] && trace=$(jq -r "$TRACE_JQ" <<<"$ev" 2>/dev/null || true)
    fi

    printf -v body '%s\n' \
      "Auto-filed from Sentry." \
      "" \
      "| | |" \
      "|---|---|" \
      "| **Sentry issue** | [${shortId}](${permalink}) |" \
      "| **Project** | \`${project}\` |" \
      "| **Level** | ${level} |" \
      "| **Events** | ${count} |" \
      "| **First seen** | ${firstSeen} |" \
      "| **Last seen** | ${lastSeen} |"

    if [ -n "$trace" ]; then
      body="${body}
<details>
<summary>Stack trace (most recent event)</summary>

\`\`\`
${trace}
\`\`\`

</details>
"
    fi

    # Keep the managed marker LAST: the dedup read greps for 'sentry-id:'.
    body="${body}
<sub>sentry-id: ${shortId} — managed marker, do not edit or remove (prevents duplicate filings).</sub>
"
    if gh issue create --repo "$GH_REPO" \
         --title "[Sentry] ${shortId}: ${title}" \
         --label "$ISSUE_LABEL" \
         --body "$body" >/dev/null; then
      echo "Filed ${shortId}: ${title}"
      echo "$shortId" >> "$seen"   # dedup within this run too
      filed=$((filed + 1))
    else
      echo "::warning::Failed to create GitHub issue for ${shortId}."
    fi
  done < <(jq -c '.[]' <<<"$resp")
done

echo "Done. Filed ${filed} new issue(s) this run."
