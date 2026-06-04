#!/bin/bash
set -eu -o pipefail

shopt -s expand_aliases
alias mktemp='mktemp --tmpdir'
alias jq='jq --unbuffered -c'

\unalias exec 2> /dev/null || true # suppress otel instrumentation for exec if instrumented because we re doing quite some magic here ...

puppeteer_in="$(mktemp -u puppeteer.in.XXXXXXXXXX.pipe)"
puppeteer_out="$(mktemp -u puppeteer.out.XXXXXXXXXX.pipe)"
mkfifo "$puppeteer_in" "$puppeteer_out"
node -e '
const repl = require("repl").start({ prompt: "", ignoreUndefined: true });
const eval = repl.eval;
repl.eval = function (code, context, replResourceName, callback) {
  try {
    return eval.call(this, code, context, replResourceName, (error, result) => {
      try {
        return callback(error, result);
      } finally {
        require("fs").writeFileSync("/tmp/autopuppeteer.repl", "");
      }
    });
  } catch (error) {
    require("fs").writeFileSync("/tmp/autopuppeteer.repl", "");
    throw error;
  }
};
repl.on("error", (error) => {
  require("fs").writeFileSync("/tmp/autopuppeteer.repl", "");
});
' < "$puppeteer_in" &> "$puppeteer_out" & puppeteer_pid="$!"
exec 4> "$puppeteer_in"
exec 5< "$puppeteer_out"
puppeteer() {
  \stdbuf -oL sed -E 's/(\.\.\.|\|) //g' < "$puppeteer_out" & puppeteer_out_pid="$!"
  local i=15
  ( grep -vE '^//' || true ) | while IFS=$'\n' read -r line; do rm -rf /tmp/autopuppeteer.repl; printf '%s\n' "$line" > "$puppeteer_in"; while ! [ -r /tmp/autopuppeteer.repl ] && [ "$i" -gt 0 ]; do sleep 1; local i=$((i - 1)); done; sleep 1; done # node is weird
  exec 3>&2
  exec 2> /dev/null
  sleep 1 && kill -9 "$puppeteer_out_pid" && { wait "$puppeteer_out_pid" || true; }
  exec 2>&3
  exec 3>&-
}

loggify_in() {
  log_in="$1"; shift
  tee "$log_in" | "$@"
}
loggify() {
  log_in="$1"; shift
  log_out="$1"; shift
  loggify_in "$log_in" "$@" | tee "$log_out"
}
if [ "${LOG_PUPPETEER:-false}" = true ]; then
  alias puppeteer='loggify /dev/stderr /dev/stderr puppeteer'
elif [ "${LOG_PUPPETEER_IN:-false}" = true ]; then
  alias puppeteer='loggify_in /dev/stderr puppeteer'
fi
if [ "${LOG_CURL:-false}" = true ]; then
  function curl() {
    id="$RANDOM"
    loggify "$(mktemp autopuppeteer.curl."$id".in.XXXXXXXXXX.json)" "$(mktemp autopuppeteer.curl."$id".out.XXXXXXXXXX.json)" command curl -v "$@" 2> "$(mktemp autopuppeteer.curl."$id".err.XXXXXXXXXX.log)"
  }
fi

if [ -n "${DISPLAY:-}" ]; then
  enrich_with_screenshot() {
    {
      cat
      local screenshot="$(mktemp)" && puppeteer << EOF &> /dev/null
await page.screenshot({ path: '$screenshot' });
EOF
      cat << EOF
"data:image/png;base64,$(base64 < "$screenshot" | tr -d '\n')"
EOF
      rm "$screenshot"
    } | jq -s '.[0].content = [ { "type": "input_text", "text": .[0].content | (if . | type == "string" then . else .[].text end) }, { "type": "input_image", "image_url": .[1] } ] | .[0]'
  }
else
  enrich_with_screenshot() {
    cat
  }
fi

puppeteer << EOF &> /dev/null
const __USERNAME__ = '$USERNAME';
const __PASSWORD__ = '$PASSWORD';
const __COOKIE__ = '$COOKIE';
EOF
exit_code=0
conversation="$(mktemp autopuppeteer.conversation.XXXXXXXXXX.json)"
jq << EOF -Rs '{ "type": "message", "role": "developer", "content": . }' >> "$conversation"
You are dynamically writing node.js code using puppeteer to achieve a given goal on a website. All output must be plain valid node.js code, no markdown or similar. You can add comments for additional context, but never use multi-line comments. Keep in mind, that the page class on recent puppeteer version do no longer contain the function "waitForTimeout".
Every message from the user will be the stdout and stderr of your own code from your last response, and optionally a screenshot of the current state. All code you write is incremental running in the same node REPL after your last code.
Think incrementally. Always plan more than one step ahead and include an output (like the entire DOM if necessary, or whether individual elements are present) that will inform the next step. Include your bigger plan as well as brief description of the current state and your conclusions in comments. If necessary adjust your plan based on the last output. Include reasoning about your conclusions and explain explicitly how the plan is adjusted.
Write minimal code, and make small steps with very few instructions at a time and reexamine the current state. Dont write entire scripts achieving all at once.
When you have achieved your goal, start your next response with a comment that is exactly "// DONE SUCCESS" and emit code to print only result and nothing else to stdout. Print it in its natural form. If its just a string, print it plain. If the result is a json, print it as json. If there is no explicit result to the task then respond with the comment alone.
When printing a result and finishing successfully, assign the result to a variable and verify its integrety. Then in a subsequent step emit code to print the result itself in plain text with the "// DONE SUCCESS" marker. This is to make sure that the print step doesnt fail and an error message is interpreted as the result. Do not just print that the result has been found and assigned to a variable, or some meta information about it. In your last step with the success marker, print the value itself.
There are several ways to extract a result, for example by extracting the right part from the DOM, to copy it via the clipboard, or read it from the screenshot and emit it as a constant.
When you are stuck and there are low chances of success, print "// DONE FAILURE". If you encounter two factor authentication that cannot be circumvented by re-entering the password, fail immediately with the right comment which indiciates failure.
If you need to use sensitive data, like username or password, assume that their raw values are stored in string constants called __USERNAME__ and __PASSWORD__ respectively.
Think extra hard and follow these instructions to the letter!
Your goal is to $GOAL.
${HINT:-}
EOF
if [ "${USE_STEALTH:-false}" = true ]; then
  jq << EOF -Rs '{ "type": "message", "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "type": "message", "role": "user", "content": . }' >> "$conversation"
const puppeteer = require('puppeteer-extra');
puppeteer.use(require('puppeteer-extra-plugin-stealth')());
EOF
else
  jq << EOF -Rs '{ "type": "message", "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "type": "message", "role": "user", "content": . }' >> "$conversation"
const puppeteer = require('puppeteer');
EOF
fi
jq << EOF -Rs '{ "type": "message", "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "type": "message", "role": "user", "content": . }' >> "$conversation"
const browser = await puppeteer.launch({ headless: $([ -n "${DISPLAY:-}" ] && echo false || echo true), defaultViewport: null, args: [ '--no-sandbox', '--disable-setuid-sandbox', $([ -z "${DISPLAY:-}" ] || echo "'--start-maximized'") ] });
const page = await browser.newPage();
EOF
puppeteer << EOF &> /dev/null
if (__COOKIE__) { await page.setExtraHTTPHeaders({ Cookie: __COOKIE__ }); }
EOF
intro_count="$(jq < "$conversation" -s length)"
jq << EOF -Rs '{ "type": "message", "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "type": "message", "role": "user", "content": . }' | enrich_with_screenshot >> "$conversation"
await page.goto('$URL', { waitUntil: 'networkidle2', });
// console.log(await page.content());
EOF
while ( ! jq < "$conversation" 'select(.type == "message") | select(.role == "assistant") | if .content | type == "string" then .content else .content[] | select(.type == "output_text") | .text end' -r | grep -F '// DONE ' > /dev/null ) && [ "$(jq < "$conversation" -s length)" -lt "${MAX_ITERATIONS:-250}" ]; do
  if [ -n "${GUARDRAIL_STRINGS:-}" ] && jq < "$conversation" '.content' -r | grep -qF -- "$GUARDRAIL_STRINGS"; then exit 2; fi
  if [ -n "${GUARDRAIL_PATTERNS:-}" ] && jq < "$conversation" '.content' -r | grep -qE -- "$GUARDRAIL_PATTERNS"; then exit 3; fi
  jq < "$conversation" -s 'del(.['"$intro_count"':-'"${MEMORY:-100}"']) | .[]' | jq -s 'del(.[:-1][].content[]? | select(.type == "input_image")) | .[]' \
    | jq -s '{ "input": ., "service_tier": "'"${OPENAI_SERVICE_TIER:-flex}"'", "model": "'"${OPENAI_MODEL:-gpt-5}"'", "reasoning": { "effort": "'"${OPENAI_REASONING_EFFORT:-high}"'" }, tools: [ { type: "web_search", search_context_size: "high" } ] }' \
    | if [ -n "${OPENAI_API_TOKEN:-}" ]; then
      curl --no-progress-meter --fail --retry 4 --max-time "$((60 * 60))" https://api.openai.com/v1/responses -H "Authorization: Bearer $OPENAI_API_TOKEN" -H "Content-Type: application/json" --data-binary @-
    elif [ -n "${GITHUB_TOKEN:-}" ]; then
      jq '{ "messages": [ .input[] | select(.type == "message") | { "role": .role, "content": ( if .content | type == "string" then .content else [ .content[] | if .type == "input_text" or .type == "output_text" then { "type": "text", "text": .text } elif .type == "input_image" then { "type": "image_url", "image_url": { "url": .image_url } } else empty end ] end ) } ], "service_tier": .service_tier, "model": ( "openai/" + .model ), "reasoning_effort": .reasoning.effort, "response_format": .text.format }' \
        | curl --no-progress-meter --fail --retry 4 --max-time "$((60 * 60))" https://models.github.ai/inference/chat/completions -H "Authorization: Bearer $GITHUB_TOKEN" -H "Content-Type: application/json" --data-binary @- \
        | jq '.choices[0].message | { output: [ { "type": "message", "role": .role, content: [ { type: "output_text", text: .content } ] } ] }'
    else
      cat > /dev/null
      echo '{ "output": [ { "type": "message", "role": "assistant", "content": [ { "type": "output_text", "text": "// DONE FAILURE (missing token)" } ] } ] }'
    fi | jq '.output[]' | tee -a "$conversation" \
    | jq 'select(.type == "message") | .content[] | select(.type == "output_text") | .text' -r \
    | puppeteer \
    | jq -Rs '{ "type": "message", "role": "user", "content": [ { "type": "input_text", "text": . } ] }' | enrich_with_screenshot >> "$conversation"
done
jq < "$conversation" 'select(.role == "assistant") | if .content | type == "string" then .content else .content[] | select(.type == "output_text") | .text end' -r | grep -qF '// DONE SUCCESS' || exit_code=1
if [ "$exit_code" = 0 ]; then jq < "$conversation" -s '.[-1] | if .content | type == "string" then .content else .content[] | select(.type == "input_text") | .text end' -r; fi
jq << EOF -Rs '{ "type": "message", "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "type": "message", "role": "user", "content": . }' >> "$conversation"
await browser.close();
// process.exit(0);
EOF

exec 4>&-
exec 5<&-
wait "$puppeteer_pid"
sleep 1
rm "$puppeteer_in" "$puppeteer_out"
exit "$exit_code"
