# Single-pass transcript squash for precompact-state.sh.
# Invoked as: jq -rR --argjson read_lines N --argjson bash_chars N -f squash.jq
# One jq process handles the whole stream (the previous bash loop spawned
# 3-4 jq processes per transcript line, which could burn the 180s hook
# timeout on large incremental diffs).
#
# Behavior per JSONL line:
# - non-JSON lines pass through unchanged
# - Read/Grep/Glob results longer than $read_lines lines, and Bash outputs
#   longer than $bash_chars chars, are replaced by a one-line placeholder
# - refs are the first few path/URL tokens (scan), capped at 300 chars —
#   the upstream version embedded whole matching strings, which could pull
#   file content into the "squashed" placeholder

def text_value:
  if type == "string" then .
  elif type == "array" then ([.[]? | if type == "string" then . elif type == "object" then (.text? // .content? // "") else "" end] | join("\n"))
  elif type == "object" then (.text? // .content? // "")
  else "" end;

. as $line
| (try fromjson catch null) as $j
| if $j == null then $line
  else
    ($j
     | [
         (.content? | text_value),
         (.message.content? | text_value),
         (.result? | text_value),
         (.output? | text_value),
         (.tool_result? | text_value)
       ]
     | map(select(. != null and . != ""))
     | (first // "")) as $text
    | ($j
       | [
           .tool_name?, .name?,
           (.message.content[]? | objects | select(.type? == "tool_use") | .name?),
           (.message.content[]? | objects | select(.type? == "tool_result") | .name?)
         ]
       | map(select(. != null and . != ""))
       | (first // "")) as $tool
    | ($text | split("\n") | length) as $lines
    | ($text | length) as $chars
    | (if ($tool == "Read" or $tool == "Grep" or $tool == "Glob") and $lines > $read_lines then true
       elif $tool == "Bash" and $chars > $bash_chars then true
       else false end) as $squash
    | if $squash | not then ($j | tojson)
      else
        ([$j | .. | strings | scan("(?:/[^[:space:]\"`]+|https?://[^[:space:]\"`]+)")]
         | unique | .[0:5] | join(" ") | .[0:300]
         | if . == "" then "unknown path" else . end) as $refs
        | if $tool == "Read" then "[Read: \($lines) lines from \($refs)]"
          elif $tool == "Bash" then "[Bash: exit \($j.exit_code // $j.status // $j.metadata.exit_code // "unknown"), \($chars) chars output; refs: \($refs)]"
          else "[\($tool): \($lines) matches; refs: \($refs)]"
          end
      end
  end
