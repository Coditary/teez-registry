-- teez cypress adapter

local current_spec = nil
local suite_stack = {}

-- Lua patterns cannot match UTF-8 symbols directly; use byte sequences.
local MARK_PASS = "\226\156\147" -- ✓
local MARK_PASS_ALT = "\226\156\148" -- ✔
local MARK_FAIL = "\195\151" -- ×
local MARK_SKIP = "\226\134\147" -- ↓
local MARK_TODO = "\226\150\161" -- □

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function target_path(context)
    return context.target_path or "."
end

local function resolve_glob_hit(root, file)
    if file:sub(1, 1) == "/" then
        return file
    end
    return root .. "/" .. file
end

local function path_excluded(target, pattern)
    return filter.glob_match(target, pattern)
end

local function default_include_patterns()
    return {
        "cypress/e2e/**/*.cy.js",
        "cypress/e2e/**/*.cy.ts",
        "cypress/e2e/**/*.cy.jsx",
        "cypress/e2e/**/*.cy.tsx",
        "cypress/integration/**/*.cy.js",
        "cypress/integration/**/*.cy.ts",
        "cypress/integration/**/*.cy.jsx",
        "cypress/integration/**/*.cy.tsx",
        "cypress/**/*.cy.js",
        "cypress/**/*.cy.ts",
        "cypress/**/*.cy.jsx",
        "cypress/**/*.cy.tsx",
    }
end

local function include_patterns(context)
    if context.runner and context.runner.include then
        return context.runner.include
    end
    return default_include_patterns()
end

local function runner_targets(context)
    local target = target_path(context)
    local patterns = include_patterns(context)

    local paths = {}
    local seen = {}
    for _, pattern in ipairs(patterns) do
        for _, file in ipairs(fs.glob(target, pattern)) do
            local resolved = resolve_glob_hit(target, file)
            local excluded = false
            if context.runner.exclude then
                for _, exclude_pattern in ipairs(context.runner.exclude) do
                    if path_excluded(resolved, exclude_pattern) then
                        excluded = true
                        break
                    end
                end
            end
            if not excluded and not seen[resolved] then
                seen[resolved] = true
                table.insert(paths, resolved)
            end
        end
    end

    if #paths == 0 then
        return { target }
    end
    return paths
end

local function cypress_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function cypress_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "cypress" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "--env")
        table.insert(args, "grep=" .. context.runner.pattern)
    end

    if context.runner.args then
        for _, arg in ipairs(context.runner.args) do
            table.insert(args, arg)
        end
    end
end

local function spec_targets(context)
    local target = target_path(context)
    local specs = {}
    for _, path in ipairs(runner_targets(context)) do
        if path ~= target and path:match("%.cy%.[%w]+$") then
            table.insert(specs, path)
        end
    end
    return specs
end

local function append_spec_targets(args, context)
    local specs = spec_targets(context)
    if #specs == 0 then
        return
    end

    table.insert(args, "--spec")
    if #specs == 1 then
        table.insert(args, specs[1])
        return
    end

    table.insert(args, table.concat(specs, ","))
end

local function build_cypress_args(context, subcommand, extra)
    local args = cypress_prefix_args(context)
    for _, token in ipairs(subcommand) do
        table.insert(args, token)
    end
    if extra then
        for _, token in ipairs(extra) do
            table.insert(args, token)
        end
    end
    append_runner_args(args, context)
    return args
end

local function normalize_path(value)
    return value:gsub("\\", "/")
end

local function relative_test_path(root, absolute_path)
    local normalized_root = normalize_path(root):gsub("/+$", "")
    local normalized_path = normalize_path(absolute_path)
    if normalized_path:sub(1, 1) ~= "/" then
        return normalized_path
    end
    local prefix = normalized_root .. "/"
    if normalized_path:sub(1, #prefix) == prefix then
        return normalized_path:sub(#prefix + 1)
    end
    return normalized_path:match("([^/]+%.[%w]+)$") or normalized_path
end

local function join_id(parts)
    return table.concat(parts, " > ")
end

local function spec_label(spec_path)
    local normalized = normalize_path(spec_path)
    return normalized:match("([^/]+%.[%w]+)$") or normalized
end

local function read_file(path)
    local handle = io.open(path, "r")
    if not handle then
        return nil
    end
    local content = handle:read("*a")
    handle:close()
    return content
end

local function push_suite(stack, name)
    table.insert(stack, name)
end

local function pop_suite(stack)
    if #stack > 0 then
        table.remove(stack)
    end
end

local function collect_tests_from_spec_content(root, spec_path, content)
    local tests = {}
    local rel = spec_label(spec_path)
    local stack = {}

    for line in content:gmatch("[^\r\n]+") do
        local test_name = line:match("it%s*%(%s*['\"]([^'\"]+)['\"]")
            or line:match("specify%s*%(%s*['\"]([^'\"]+)['\"]")
        local suite = line:match("describe%s*%(%s*['\"]([^'\"]+)['\"]")
            or line:match("context%s*%(%s*['\"]([^'\"]+)['\"]")

        if suite then
            push_suite(stack, suite)
        end

        if test_name then
            local parts = { rel }
            for _, suite_name in ipairs(stack) do
                table.insert(parts, suite_name)
            end
            table.insert(parts, test_name)
            table.insert(tests, join_id(parts))
        elseif line:match("^%s*}%s*%)%s*;?%s*$") then
            pop_suite(stack)
        end
    end

    return tests
end

local function collect_tests_from_specs(context)
    local tests = {}
    local root = target_path(context)

    for _, spec_path in ipairs(runner_targets(context)) do
        local content = read_file(spec_path)
        if content then
            for _, test_id in ipairs(collect_tests_from_spec_content(root, spec_path, content)) do
                table.insert(tests, test_id)
            end
        else
            table.insert(tests, relative_test_path(root, spec_path))
        end
    end

    table.sort(tests)
    return tests
end

local function dry_run_failed(output)
    if not output or output == "" then
        return true
    end
    return output:match("unknown option: %-%-dry%-run") ~= nil
        or output:match("unknown option: dry%-run") ~= nil
end

local function collect_tests_from_dry_run(context, output)
    local tests = {}
    local root = target_path(context)

    for line in output:gmatch("[^\r\n]+") do
        local spec = line:match("Running:%s+(%S+)")
        if spec then
            table.insert(tests, relative_test_path(root, spec))
            goto continue
        end

        local rel = line:match("^%s*(cypress/.+%.cy%.[%w]+)%s*$")
        if rel then
            table.insert(tests, rel)
        end

        ::continue::
    end

    table.sort(tests)
    return tests
end

local function safe_exec(command, args)
    local ok, output = pcall(function()
        return sys.exec(command, args)
    end)
    if not ok then
        return nil
    end
    return output
end

local function collect_tests_with_dry_run(context)
    local args = build_cypress_args(context, { "run" }, { "--dry-run" })
    append_spec_targets(args, context)

    local output = safe_exec(cypress_command(context), args)
    if not output or dry_run_failed(output) then
        return {}
    end

    local tests = collect_tests_from_dry_run(context, output)
    if #tests > 0 then
        return tests
    end
    return {}
end

local function collect_tests(context)
    local dry_run_tests = collect_tests_with_dry_run(context)
    if #dry_run_tests > 0 then
        return dry_run_tests
    end

    return collect_tests_from_specs(context)
end

local function shallow_merge(base, overrides)
    local merged = {}
    for key, value in pairs(base) do
        merged[key] = value
    end
    if type(overrides) == "table" then
        for key, value in pairs(overrides) do
            merged[key] = value
        end
    end
    return merged
end

local function runner_cfg(context)
    if type(context.runner) == "table" then
        return context.runner
    end
    return {}
end

local function coverage_cfg(context)
    local cfg = runner_cfg(context)
    local from_runner = type(cfg.coverage) == "table" and cfg.coverage or {}
    local from_global = type(config) == "table" and type(config.coverage) == "table" and config.coverage
        or {}
    return shallow_merge(from_global, from_runner)
end

local function default_coverage_cfg(_context)
    return {
        reports_directory = "coverage",
        report = "coverage/lcov.info",
        output = "coverage/teez.msgpack",
        reporter = "msgpack",
    }
end

local function effective_coverage_cfg(context)
    return shallow_merge(default_coverage_cfg(context), coverage_cfg(context))
end

local function reporter_args(context)
    local reporter = "spec"
    if context.runner and context.runner.reporter then
        reporter = context.runner.reporter
    end
    return { "--reporter", reporter }
end

local function update_running_spec(line)
    local spec = line:match("Running:%s+(%S+)")
    if spec then
        current_spec = spec
        suite_stack = {}
        return true
    end
    return false
end

local function update_suite_stack(line)
    local suite = trim(line)
    if suite == "" then
        return false
    end
    if suite:match("^" .. MARK_PASS)
        or suite:match("^" .. MARK_PASS_ALT)
        or suite:match("^" .. MARK_FAIL)
        or suite:match("^[xX]")
        or suite:match("^" .. MARK_SKIP)
        or suite:match("^" .. MARK_TODO)
        or suite:match("^%d+%)") then
        return false
    end
    if line:match("^%s+[^%s]") and not line:match("^%s*" .. MARK_PASS)
        and not line:match("^%s*" .. MARK_PASS_ALT)
        and not line:match("^%s*%d+%)")
        and not line:match("^%s*" .. MARK_FAIL)
        and not line:match("^%s*[xX]")
        and not line:match("^%s*" .. MARK_SKIP)
        and not line:match("^%s*" .. MARK_TODO) then
        suite_stack = { suite }
        return true
    end
    return false
end

local function build_test_id(test_name)
    local parts = {}
    if current_spec then
        table.insert(parts, current_spec)
    end
    for _, suite in ipairs(suite_stack) do
        table.insert(parts, suite)
    end
    table.insert(parts, test_name)
    return join_id(parts)
end

local function split_result_tail(tail)
    local duration_ms = tail:match("(%d+)ms$")
    if duration_ms then
        local id = trim(tail:gsub("%s+%d+ms$", ""))
        return id, tonumber(duration_ms)
    end
    return trim(tail), nil
end

local function with_duration(event, duration_ms)
    if duration_ms ~= nil then
        event.duration_ms = duration_ms
    end
    return event
end

local function looks_like_summary_noise(line)
    if line:find("All specs passed", 1, true) then
        return true
    end
    if line:find("of", 1, true) and line:find("failed", 1, true) and line:find("%(", 1, true) then
        return true
    end
    return false
end

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    local args = build_cypress_args(context, { "run" }, reporter_args(context))
    append_spec_targets(args, context)

    return {
        command = cypress_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local extra = reporter_args(context)
    table.insert(extra, "--env")
    table.insert(extra, "coverage=true")

    local args = build_cypress_args(context, { "run" }, extra)
    append_spec_targets(args, context)

    return {
        command = cypress_command(context),
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
        note = "Requires @cypress/code-coverage in cypress.config and instrumented application code",
    }
end

function parse_line(line)
    if looks_like_summary_noise(line) then
        return nil
    end

    if update_running_spec(line) then
        return nil
    end

    if update_suite_stack(line) then
        return nil
    end

    local pass_tail = line:match("^%s*" .. MARK_PASS .. "%s+(.+)$")
        or line:match("^%s*" .. MARK_PASS_ALT .. "%s+(.+)$")
    if pass_tail then
        local test_name, duration_ms = split_result_tail(pass_tail)
        return with_duration({ event = "pass", id = build_test_id(test_name) }, duration_ms)
    end

    local fail_tail = line:match("^%s*%d+%)%s+(.+)$")
        or line:match("^%s*" .. MARK_FAIL .. "%s+(.+)$")
        or line:match("^%s*[xX]%s+(.+)$")
    if fail_tail then
        local test_name, duration_ms = split_result_tail(fail_tail)
        return with_duration({ event = "fail", id = build_test_id(test_name), msg = "FAILED" }, duration_ms)
    end

    local skip_tail = line:match("^%s*" .. MARK_SKIP .. "%s+(.+)$")
        or line:match("^%s*%-%s+(.+)$")
    if skip_tail then
        local test_name, duration_ms = split_result_tail(skip_tail)
        return with_duration({ event = "skip", id = build_test_id(test_name) }, duration_ms)
    end

    local todo_tail = line:match("^%s*" .. MARK_TODO .. "%s+(.+)$")
    if todo_tail then
        local test_name, duration_ms = split_result_tail(todo_tail)
        return with_duration({ event = "todo", id = build_test_id(test_name) }, duration_ms)
    end

    return nil
end
