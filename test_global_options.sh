#!/bin/bash

PASS_COUNT=0
FAIL_COUNT=0
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
GIT_WRAPPER="$SCRIPT_DIR/executable_git"
REAL_EXEC_PATH="$(git --exec-path)"

pass() {
    echo "PASS: $1"
    PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
    echo "FAIL: $1"
    echo "      $2"
    FAIL_COUNT=$((FAIL_COUNT + 1))
}

setup_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test_global_options.XXXXXX")
    git init -q "$tmpdir"
    git -C "$tmpdir" config user.name "Human User"
    git -C "$tmpdir" config user.email "human@example.com"
    git -C "$tmpdir" commit --allow-empty -m "Initial commit" -q
    git -C "$tmpdir" config core.hooksPath "$tmpdir/.hooks"
    mkdir -p "$tmpdir/.hooks"
    printf '#!/bin/sh\nexit 0\n' > "$tmpdir/.hooks/pre-commit"
    chmod +x "$tmpdir/.hooks/pre-commit"
    echo "/.hooks/" >> "$tmpdir/.git/info/exclude"
    echo "content" > "$tmpdir/file.txt"
    echo "$tmpdir"
}

cleanup_repo() {
    cd "$SCRIPT_DIR" || exit 1
    rm -rf "$1"
}

HUMAN_WRAPPER=$(mktemp "${TMPDIR:-/tmp}/human_git_wrapper.XXXXXX")
sed '/^# Main script$/i\
ami_detect() { echo "none"; }\
detect_ai_tool() { echo "none"; }\
ami_is_ai() { return 1; }\
' "$GIT_WRAPPER" > "$HUMAN_WRAPPER"
chmod +x "$HUMAN_WRAPPER"
HOOKS_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hooks_config.XXXXXX")
printf '[core]\n\thooksPath = /dev/null\n' > "$HOOKS_CONFIG"
trap 'rm -f "$HUMAN_WRAPPER" "$HOOKS_CONFIG"' EXIT

prefix_for() {
    local name="$1" repo="$2"
    case "$name" in
        none) PREFIX=() ;;
        c) PREFIX=(-c user.name=x) ;;
        multi-c) PREFIX=(-c user.name=x -c user.email=x@example.com) ;;
        C) PREFIX=(-C "$repo") ;;
        git-dir-eq) PREFIX=("--git-dir=$repo/.git" "--work-tree=$repo") ;;
        git-dir-sep) PREFIX=(--git-dir "$repo/.git" --work-tree "$repo") ;;
        namespace-eq) PREFIX=(--namespace=ns) ;;
        namespace-sep) PREFIX=(--namespace ns) ;;
        config-env-eq) PREFIX=(--config-env=foo.bar=HOME) ;;
        config-env-sep) PREFIX=(--config-env foo.bar=HOME) ;;
        exec-path) PREFIX=("--exec-path=$REAL_EXEC_PATH") ;;
        no-pager) PREFIX=(--no-pager) ;;
        p) PREFIX=(-p) ;;
        P) PREFIX=(-P) ;;
        paginate) PREFIX=(--paginate) ;;
        literal-pathspecs) PREFIX=(--literal-pathspecs) ;;
        no-literal-pathspecs) PREFIX=(--no-literal-pathspecs) ;;
        shallow-file) PREFIX=(--shallow-file /dev/null) ;;
        no-replace-objects) PREFIX=(--no-replace-objects) ;;
        combined) PREFIX=(--no-pager -C "$repo" -c user.name=x --literal-pathspecs) ;;
    esac
}

PREFIXES="none c multi-c C git-dir-eq git-dir-sep namespace-eq namespace-sep config-env-eq config-env-sep exec-path no-pager p P paginate literal-pathspecs no-literal-pathspecs shallow-file no-replace-objects combined"

echo "=== Testing global options before the subcommand ==="
echo ""

for name in $PREFIXES; do
    for add_form in "-A" "--all" "."; do
        repo=$(setup_repo)
        prefix_for "$name" "$repo"
        cd "$repo" || exit 1

        output=$(PAGER="cat" CLAUDECODE=1 "$GIT_WRAPPER" "${PREFIX[@]}" add "$add_form" 2>&1)
        status=$?
        staged=$(git diff --cached --name-only)
        if [ $status -ne 0 ] && [[ "$output" == *"is not allowed when running under AI control"* ]] && [ -z "$staged" ]; then
            pass "AI refused: git ${PREFIX[*]} add $add_form"
        else
            fail "AI refused: git ${PREFIX[*]} add $add_form" "status=$status staged='$staged' output='$output'"
        fi

        output=$(PAGER="cat" "$HUMAN_WRAPPER" "${PREFIX[@]}" add "$add_form" 2>&1)
        status=$?
        staged=$(git diff --cached --name-only)
        if [ $status -eq 0 ] && [ "$staged" = "file.txt" ]; then
            pass "Human allowed: git ${PREFIX[*]} add $add_form"
        else
            fail "Human allowed: git ${PREFIX[*]} add $add_form" "status=$status staged='$staged' output='$output'"
        fi

        cleanup_repo "$repo"
    done
done

for name in $PREFIXES; do
    for nv_form in "--no-verify" "-n"; do
        repo=$(setup_repo)
        prefix_for "$name" "$repo"
        cd "$repo" || exit 1
        git add file.txt

        output=$(PAGER="cat" CLAUDECODE=1 "$GIT_WRAPPER" "${PREFIX[@]}" commit "$nv_form" -m "msg" 2>&1)
        status=$?
        count=$(git rev-list --count HEAD)
        if [ $status -ne 0 ] && [[ "$output" == *"trying to bypass commit hooks"* ]] && [ "$count" -eq 1 ]; then
            pass "AI refused: git ${PREFIX[*]} commit $nv_form"
        else
            fail "AI refused: git ${PREFIX[*]} commit $nv_form" "status=$status commits=$count output='$output'"
        fi

        output=$(PAGER="cat" "$HUMAN_WRAPPER" "${PREFIX[@]}" commit "$nv_form" -m "msg" 2>&1)
        status=$?
        count=$(git rev-list --count HEAD)
        if [ $status -eq 0 ] && [ "$count" -eq 2 ]; then
            pass "Human allowed: git ${PREFIX[*]} commit $nv_form"
        else
            fail "Human allowed: git ${PREFIX[*]} commit $nv_form" "status=$status commits=$count output='$output'"
        fi

        cleanup_repo "$repo"
    done
done

repo=$(setup_repo)
cd "$SCRIPT_DIR" || exit 1
output=$(CLAUDECODE=1 "$GIT_WRAPPER" -C "$repo" add -A -- file.txt 2>&1)
status=$?
staged=$(git -C "$repo" diff --cached --name-only)
if [ $status -eq 0 ] && [ "$staged" = "file.txt" ]; then
    pass "AI allowed: git -C <repo> add -A -- file.txt"
else
    fail "AI allowed: git -C <repo> add -A -- file.txt" "status=$status staged='$staged' output='$output'"
fi

output=$(CLAUDECODE=1 "$GIT_WRAPPER" -C "$repo" -c user.name=Impostor commit -m "AI change" 2>&1)
status=$?
author=$(git -C "$repo" log -1 --format='%an <%ae>')
trailer=$(git -C "$repo" log -1 --format='%(trailers:key=Signed-off-by,valueonly)' | head -n 1)
if [ $status -eq 0 ] && [[ "$author" != "Impostor"* ]] && [[ "$author" != "Human User"* ]] && [ -n "$author" ] && [ "$trailer" = "Human User <human@example.com>" ]; then
    pass "AI commit via -C/-c keeps AI author and human trailer"
else
    fail "AI commit via -C/-c keeps AI author and human trailer" "status=$status author='$author' trailer='$trailer' output='$output'"
fi
cleanup_repo "$repo"

repo=$(setup_repo)
git -C "$repo" config ai-aligned.require-prompt true
git -C "$repo" add file.txt
cd "$SCRIPT_DIR" || exit 1
output=$(CLAUDECODE=1 "$GIT_WRAPPER" -C "$repo" -c ai-aligned.require-prompt=false commit -m "AI change" 2>&1)
status=$?
count=$(git -C "$repo" rev-list --count HEAD)
if [ $status -ne 0 ] && [[ "$output" == *"requires AI commits to include a prompt summary"* ]] && [ "$count" -eq 1 ]; then
    pass "AI cannot override repo policy with -c ai-aligned.require-prompt=false"
else
    fail "AI cannot override repo policy with -c ai-aligned.require-prompt=false" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"

bare=$(mktemp -d "${TMPDIR:-/tmp}/test_global_options.XXXXXX")
git init -q --bare "$bare"
cd "$bare" || exit 1
output=$(CLAUDECODE=1 "$GIT_WRAPPER" --bare add -A 2>&1)
status=$?
if [ $status -ne 0 ] && [[ "$output" == *"is not allowed when running under AI control"* ]]; then
    pass "AI refused: git --bare add -A"
else
    fail "AI refused: git --bare add -A" "status=$status output='$output'"
fi
output=$("$HUMAN_WRAPPER" --bare add -A 2>&1)
if [[ "$output" != *"is not allowed when running under AI control"* ]]; then
    pass "Human not refused by wrapper: git --bare add -A"
else
    fail "Human not refused by wrapper: git --bare add -A" "output='$output'"
fi
cleanup_repo "$bare"

output=$(CLAUDECODE=1 "$GIT_WRAPPER" --no-pager --version 2>&1)
if [ $? -eq 0 ] && [[ "$output" == "git version"* ]]; then
    pass "Global options without subcommand pass through"
else
    fail "Global options without subcommand pass through" "output='$output'"
fi

run_hooks_case() {
    local label="$1"
    shift
    local repo output status count
    repo=$(setup_repo)
    cd "$repo" || exit 1
    git add file.txt
    output=$(env CLAUDECODE=1 "$@" "$GIT_WRAPPER" "${CASE_ARGS[@]}" commit -m "msg" 2>&1)
    status=$?
    count=$(git rev-list --count HEAD)
    if [ $status -ne 0 ] && [[ "$output" == *"overriding core.hooksPath, alias.* or include.*"* ]] && [ "$count" -eq 1 ]; then
        pass "AI refused: $label"
    else
        fail "AI refused: $label" "status=$status commits=$count output='$output'"
    fi
    output=$(env "$@" "$HUMAN_WRAPPER" "${CASE_ARGS[@]}" commit -m "msg" 2>&1)
    status=$?
    count=$(git rev-list --count HEAD)
    if [ $status -eq 0 ] && [ "$count" -eq 2 ]; then
        pass "Human allowed: $label"
    else
        fail "Human allowed: $label" "status=$status commits=$count output='$output'"
    fi
    cleanup_repo "$repo"
}

CASE_ARGS=(-c core.hooksPath=/dev/null)
run_hooks_case "git -c core.hooksPath=/dev/null commit" PAGER="cat"
CASE_ARGS=(-c core.hookspath=/dev/null)
run_hooks_case "git -c core.hookspath=/dev/null commit" PAGER="cat"
CASE_ARGS=(-c CORE.HOOKSPATH=/dev/null)
run_hooks_case "git -c CORE.HOOKSPATH=/dev/null commit" PAGER="cat"
CASE_ARGS=(--config-env core.hooksPath=HOOKS_DIR)
run_hooks_case "git --config-env core.hooksPath=HOOKS_DIR commit" HOOKS_DIR=/dev/null
CASE_ARGS=(--config-env=core.hooksPath=HOOKS_DIR)
run_hooks_case "git --config-env=core.hooksPath=HOOKS_DIR commit" HOOKS_DIR=/dev/null
CASE_ARGS=()
run_hooks_case "GIT_CONFIG_KEY_0=core.hooksPath git commit" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
run_hooks_case "GIT_CONFIG_KEY_1=core.hooksPath git commit" GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0=x GIT_CONFIG_KEY_1=core.hooksPath GIT_CONFIG_VALUE_1=/dev/null
run_hooks_case "GIT_CONFIG_PARAMETERS core.hooksPath git commit" "GIT_CONFIG_PARAMETERS='core.hooksPath'='/dev/null'"
repo=$(setup_repo)
cd "$repo" || exit 1
git add file.txt
output=$(CLAUDECODE=1 GIT_CONFIG_PARAMETERS="core.hooksPath=/dev/null" "$GIT_WRAPPER" commit -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -ne 0 ] && [[ "$output" == *"overriding core.hooksPath, alias.* or include.*"* ]] && [ "$count" -eq 1 ]; then
    pass "AI refused: old-style GIT_CONFIG_PARAMETERS core.hooksPath git commit"
else
    fail "AI refused: old-style GIT_CONFIG_PARAMETERS core.hooksPath git commit" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"
CASE_ARGS=(-c "include.path=$HOOKS_CONFIG")
run_hooks_case "git -c include.path=<file> commit" PAGER="cat"
CASE_ARGS=(-c "includeIf.gitdir:/.path=$HOOKS_CONFIG")
run_hooks_case "git -c includeIf.gitdir:/.path=<file> commit" PAGER="cat"
CASE_ARGS=()
run_hooks_case "GIT_CONFIG_KEY_0=include.path git commit" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=include.path "GIT_CONFIG_VALUE_0=$HOOKS_CONFIG"
run_hooks_case "GIT_CONFIG_COUNT=+1 core.hooksPath git commit" "GIT_CONFIG_COUNT=+1" GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
run_hooks_case "GIT_CONFIG_COUNT=' 1' core.hooksPath git commit" "GIT_CONFIG_COUNT= 1" GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
run_hooks_case "GIT_CONFIG_COUNT=<tab>1 core.hooksPath git commit" "GIT_CONFIG_COUNT=$(printf '\t')1" GIT_CONFIG_KEY_0=core.hooksPath GIT_CONFIG_VALUE_0=/dev/null
CASE_ARGS=(-c alias.ci=commit)
run_hooks_case "git -c alias.ci=commit commit" PAGER="cat"
CASE_ARGS=(--config-env alias.ci=ALIAS_VALUE)
run_hooks_case "git --config-env alias.ci=ALIAS_VALUE commit" ALIAS_VALUE=commit
CASE_ARGS=()
run_hooks_case "GIT_CONFIG_KEY_0=alias.ci git commit" GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.ci GIT_CONFIG_VALUE_0=commit

repo=$(setup_repo)
cd "$repo" || exit 1
git config core.hooksPath ""
git config --unset core.hooksPath
git add file.txt
output=$(CLAUDECODE=1 GIT_CONFIG_GLOBAL="$HOOKS_CONFIG" "$GIT_WRAPPER" commit -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -ne 0 ] && [[ "$output" == *"changing core.hooksPath through GIT_CONFIG_GLOBAL"* ]] && [ "$count" -eq 1 ]; then
    pass "AI refused: GIT_CONFIG_GLOBAL=<file setting hooksPath> git commit"
else
    fail "AI refused: GIT_CONFIG_GLOBAL=<file setting hooksPath> git commit" "status=$status commits=$count output='$output'"
fi
output=$(GIT_CONFIG_GLOBAL="$HOOKS_CONFIG" "$HUMAN_WRAPPER" commit -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -eq 0 ] && [ "$count" -eq 2 ]; then
    pass "Human allowed: GIT_CONFIG_GLOBAL=<file setting hooksPath> git commit"
else
    fail "Human allowed: GIT_CONFIG_GLOBAL=<file setting hooksPath> git commit" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"

EMPTY_HOOKS_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hooks_config.XXXXXX")
printf '[core]\n\thooksPath =\n' > "$EMPTY_HOOKS_CONFIG"
repo=$(setup_repo)
cd "$repo" || exit 1
git config --unset core.hooksPath
git add file.txt
output=$(CLAUDECODE=1 GIT_CONFIG_GLOBAL="$EMPTY_HOOKS_CONFIG" "$GIT_WRAPPER" commit -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -ne 0 ] && [[ "$output" == *"changing core.hooksPath through GIT_CONFIG_GLOBAL"* ]] && [ "$count" -eq 1 ]; then
    pass "AI refused: GIT_CONFIG_GLOBAL=<file with empty hooksPath> git commit"
else
    fail "AI refused: GIT_CONFIG_GLOBAL=<file with empty hooksPath> git commit" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"
rm -f "$EMPTY_HOOKS_CONFIG"

repo=$(setup_repo)
cd "$repo" || exit 1
git add file.txt
output=$(CLAUDECODE=1 GIT_CONFIG_GLOBAL=/dev/null "$GIT_WRAPPER" commit -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -eq 0 ] && [ "$count" -eq 2 ]; then
    pass "AI allowed: GIT_CONFIG_GLOBAL that leaves hooksPath unchanged"
else
    fail "AI allowed: GIT_CONFIG_GLOBAL that leaves hooksPath unchanged" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"

repo=$(setup_repo)
cd "$repo" || exit 1
output=$(CLAUDECODE=1 "$GIT_WRAPPER" --frobnicate add -A 2>&1)
status=$?
staged=$(git diff --cached --name-only)
if [ $status -ne 0 ] && [[ "$output" == *"unrecognised global option '--frobnicate'"* ]] && [ -z "$staged" ]; then
    pass "AI refused: git --frobnicate add -A"
else
    fail "AI refused: git --frobnicate add -A" "status=$status staged='$staged' output='$output'"
fi
output=$("$HUMAN_WRAPPER" --frobnicate add -A 2>&1)
if [[ "$output" != *"not allowed when running under AI control"* ]] && [[ "$output" == *"frobnicate"* ]]; then
    pass "Human gets git's own error: git --frobnicate add -A"
else
    fail "Human gets git's own error: git --frobnicate add -A" "output='$output'"
fi
cleanup_repo "$repo"

for alias_case in "sh|!git add -A" "deep|chain"; do
    alias_name="${alias_case%%|*}"
    alias_value="${alias_case#*|}"
    repo=$(setup_repo)
    cd "$repo" || exit 1
    if [ "$alias_value" = "chain" ]; then
        git config alias.d11 "add -A"
        for level in 10 9 8 7 6 5 4 3 2 1 0; do
            git config "alias.d$level" "d$((level + 1))"
        done
        git config alias.deep d0
    else
        git config "alias.$alias_name" "$alias_value"
    fi
    output=$(CLAUDECODE=1 "$GIT_WRAPPER" "$alias_name" 2>&1)
    status=$?
    staged=$(git diff --cached --name-only)
    if [ $status -ne 0 ] && [[ "$output" == *"not allowed when running under AI control"* ]] && [ -z "$staged" ]; then
        pass "AI refused: alias $alias_name ($alias_value)"
    else
        fail "AI refused: alias $alias_name ($alias_value)" "status=$status staged='$staged' output='$output'"
    fi
    output=$("$HUMAN_WRAPPER" "$alias_name" 2>&1)
    status=$?
    staged=$(git diff --cached --name-only)
    if [ $status -eq 0 ] && [ "$staged" = "file.txt" ]; then
        pass "Human allowed: alias $alias_name ($alias_value)"
    else
        fail "Human allowed: alias $alias_name ($alias_value)" "status=$status staged='$staged' output='$output'"
    fi
    cleanup_repo "$repo"
done

repo=$(setup_repo)
cd "$repo" || exit 1
output=$(CLAUDECODE=1 "$GIT_WRAPPER" -c "alias.aa=add -A" aa 2>&1)
status=$?
staged=$(git diff --cached --name-only)
if [ $status -ne 0 ] && [ -z "$staged" ]; then
    pass "AI refused: git -c alias.aa='add -A' aa"
else
    fail "AI refused: git -c alias.aa='add -A' aa" "status=$status staged='$staged' output='$output'"
fi
output=$("$HUMAN_WRAPPER" -c "alias.aa=add -A" aa 2>&1)
status=$?
staged=$(git diff --cached --name-only)
if [ $status -eq 0 ] && [ "$staged" = "file.txt" ]; then
    pass "Human allowed: git -c alias.aa='add -A' aa"
else
    fail "Human allowed: git -c alias.aa='add -A' aa" "status=$status staged='$staged' output='$output'"
fi
cleanup_repo "$repo"

for alias_case in "aa|add -A" "ad|add ." "chain|aa"; do
    alias_name="${alias_case%%|*}"
    alias_value="${alias_case#*|}"
    repo=$(setup_repo)
    cd "$repo" || exit 1
    git config alias.aa "add -A"
    git config "alias.$alias_name" "$alias_value"
    output=$(CLAUDECODE=1 "$GIT_WRAPPER" "$alias_name" 2>&1)
    status=$?
    staged=$(git diff --cached --name-only)
    if [ $status -ne 0 ] && [[ "$output" == *"is not allowed when running under AI control"* ]] && [ -z "$staged" ]; then
        pass "AI refused: configured alias $alias_name='$alias_value'"
    else
        fail "AI refused: configured alias $alias_name='$alias_value'" "status=$status staged='$staged' output='$output'"
    fi
    output=$("$HUMAN_WRAPPER" "$alias_name" 2>&1)
    status=$?
    staged=$(git diff --cached --name-only)
    if [ $status -eq 0 ] && [ "$staged" = "file.txt" ]; then
        pass "Human allowed: configured alias $alias_name='$alias_value'"
    else
        fail "Human allowed: configured alias $alias_name='$alias_value'" "status=$status staged='$staged' output='$output'"
    fi
    cleanup_repo "$repo"
done

repo=$(setup_repo)
cd "$repo" || exit 1
git config alias.cnv "commit --no-verify"
git add file.txt
output=$(CLAUDECODE=1 "$GIT_WRAPPER" -C "$repo" cnv -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -ne 0 ] && [[ "$output" == *"trying to bypass commit hooks"* ]] && [ "$count" -eq 1 ]; then
    pass "AI refused: configured alias cnv='commit --no-verify'"
else
    fail "AI refused: configured alias cnv='commit --no-verify'" "status=$status commits=$count output='$output'"
fi
output=$("$HUMAN_WRAPPER" -C "$repo" cnv -m "msg" 2>&1)
status=$?
count=$(git rev-list --count HEAD)
if [ $status -eq 0 ] && [ "$count" -eq 2 ]; then
    pass "Human allowed: configured alias cnv='commit --no-verify'"
else
    fail "Human allowed: configured alias cnv='commit --no-verify'" "status=$status commits=$count output='$output'"
fi
cleanup_repo "$repo"

repo=$(setup_repo)
cd "$repo" || exit 1
git config alias.cm "commit -m 'two words'"
git add file.txt
output=$(CLAUDECODE=1 "$GIT_WRAPPER" cm 2>&1)
status=$?
subject=$(git log -1 --format=%s)
author=$(git log -1 --format='%an')
if [ $status -eq 0 ] && [ "$subject" = "two words" ] && [ "$author" != "Human User" ]; then
    pass "AI commit through quoted alias keeps message and AI author"
else
    fail "AI commit through quoted alias keeps message and AI author" "status=$status subject='$subject' author='$author' output='$output'"
fi
cleanup_repo "$repo"

repo=$(setup_repo)
cd "$repo" || exit 1
git config alias.status "add -A"
output=$(CLAUDECODE=1 "$GIT_WRAPPER" status --short 2>&1)
status=$?
staged=$(git diff --cached --name-only)
if [ $status -eq 0 ] && [[ "$output" == *"file.txt"* ]] && [ -z "$staged" ]; then
    pass "Alias shadowing a builtin is ignored like git does"
else
    fail "Alias shadowing a builtin is ignored like git does" "status=$status staged='$staged' output='$output'"
fi
cleanup_repo "$repo"

echo ""
echo "=== Results ==="
echo "Passed: $PASS_COUNT"
echo "Failed: $FAIL_COUNT"
echo "Total:  $((PASS_COUNT + FAIL_COUNT))"

if [ "$FAIL_COUNT" -gt 0 ]; then
    exit 1
fi
