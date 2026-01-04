#!/bin/bash
set -eu -o pipefail

puppeteer_in="$(mktemp -u puppeteer.in.XXXXXXXXXX.pipe)"
puppeteer_out="$(mktemp -u puppeteer.out.XXXXXXXXXX.pipe)"
mkfifo "$puppeteer_in" "$puppeteer_out"
# script -q -c node /dev/null < "$in" &> "$out" & puppeteer_pid="$!"
node -e 'require("repl").start({ prompt: "", ignoreUndefined: true })' < "$puppeteer_in" &> "$puppeteer_out" & puppeteer_pid="$!"
exec 4> "$puppeteer_in"
exec 5< "$puppeteer_out"
puppeteer() {
  stdbuf -oL sed 's/\.\.\. //g' < "$puppeteer_out" & puppeteer_out_pid="$!"
  while IFS=$'\n' read -r line; do sleep 5; printf '%s\n' "$line" > "$puppeteer_in"; done # node is weird
  exec 3>&2
  exec 2> /dev/null
  sleep 5 && kill -9 "$puppeteer_out_pid" && { wait "$puppeteer_out_pid" || true; }
  exec 2>&3
  exec 3>&-
}

shopt -s expand_aliases
alias jq='jq --unbuffered -c'

loggify() {
  tee /dev/stderr | "$@" | tee /dev/stderr
}

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
    } | jq -s '.[0].content = [ { "type": "text", "text": .[0].content }, { "type": "image_url", "image_url": { "url": .[1] } } ] | .[0]'
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
const __URL__ = '$URL';
EOF
conversation="$(mktemp puppeteer.conversation.XXXXXXXXXX.json)"
jq << EOF -Rs '{ "role": "developer", "content": . }' >> "$conversation"
You are dynamically writing node.js code using puppeteer to achieve a given goal on a website. All output must be plain valid node.js code, no markdown or similar. You can add comments for additional context.
Every message from the user will be the stdout and stderr of your own code from your last response, and optionally a screenshot of the current state. All code you write is incremental running in the same node REPL after your last code.
Think incrementally. Always plan more than one step ahead and include an output (like the entire DOM if necessary, or whether individual elements are present) that will inform the next step. Include your bigger plan in comments. If necessary adjust your plan based on the last output. Include reasoning about your conclusions and explain explicitly how the plan is adjusted.
Write minimal code, and make small steps with very few instructions at a time and reexamine the current state. Dont write entire scripts achieving all at once.
When you have achieved your goal, start your next response with a comment that is exactly "// DONE SUCCESS" and emit code to print only result and nothing else to stdout. Print it in its natural form. If its just a string, print it plain. If the result is a json, print it as json. If there is no explicit result to the task then respond with the comment alone.
When you are stuck and there are low chances of success, print "// DONE FAILURE".
Never directly print sensitive data like usernames, passwords, or cookies. Only write code to handle them directly via variables.
If you need to use sensitive data, like username or password, assume that their raw values are stored in string constants called __USERNAME__ and __PASSWORD__ respectively.
Think extra hard and follow these instructions to the letter!
Your goal is to $GOAL starting at $URL.
${HINT:-}
EOF
if [ "${USE_STEALTH:-false}" = true ]; then
  jq << EOF -Rs '{ "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "role": "user", "content": . }' >> "$conversation"
const puppeteer = require('puppeteer-extra');
puppeteer.use(require('puppeteer-extra-plugin-stealth')());
EOF
else
  jq << EOF -Rs '{ "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "role": "user", "content": . }' >> "$conversation"
const puppeteer = require('puppeteer');
EOF
fi
jq << EOF -Rs '{ "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "role": "user", "content": . }' >> "$conversation"
const browser = await puppeteer.launch({ headless: $([ -n "${DISPLAY:-}" ] && echo false || echo true), defaultViewport: null, args: [ '--no-sandbox', '--disable-setuid-sandbox', $([ -z "${DISPLAY:-}" ] || echo "'--start-maximized'") ] });
const page = await browser.newPage();
EOF
puppeteer << EOF &> /dev/null
if (__COOKIE__) { await page.setExtraHTTPHeaders({ Cookie: __COOKIE__ }); }
EOF
intro_count="$(wc -l < "$conversation")"
jq << EOF -Rs '{ "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "role": "user", "content": . }' | enrich_with_screenshot >> "$conversation"
await page.goto(__URL__, { waitUntil: 'networkidle2', });
console.log(await page.content());
EOF
while [ "$(jq < "$conversation" 'select(if .content | type == "string" then .content else .content[] | select(.type == "text") | .text end | startswith("// DONE "))' | wc -l)" = 0 ]; do
  jq < "$conversation" -s 'del(.['"$intro_count"':-'"${MEMORY:-25}"']) | .[]' | jq -s 'del(.[:-3][] | if .content | type == "string" then empty else .content[] | select(.type != "text") end) | .[]' \
    | jq -s '{ "model": "'"${OPENAI_MODEL:-gpt-5.1}"'", "reasoning_effort": "'"${OPENAI_REASONING_EFFORT:-high}"'", "messages": . }' \
    | curl --no-progress-meter --fail --retry 4 --max-time "$((60 * 60))" https://api.openai.com/v1/chat/completions -H "Authorization: Bearer $OPENAI_API_TOKEN" -H "Content-Type: application/json" --data-binary @- \
    | jq '.choices[0].message | { role: .role, content: .content }' | tee -a "$conversation" \
    | jq .content -r | ( grep -vE '^//' || true ) | tee /dev/stderr | puppeteer | jq -Rs '{ "role": "user", "content": . }' | enrich_with_screenshot >> "$conversation"
done
jq < "$conversation" -s '.[-1] | if .content | type == "string" then .content else .content[] | select(.type == "text") | .text end' -r
jq << EOF -Rs '{ "role": "assistant", "content": . }' | tee -a "$conversation" | jq .content -r | puppeteer | jq -Rs '{ "role": "user", "content": . }' >> "$conversation"
await browser.close();
// process.exit(0);
EOF

exec 4>&-
exec 5<&-
wait "$puppeteer_pid"
sleep 1
rm "$conversation" "$puppeteer_in" "$puppeteer_out"
