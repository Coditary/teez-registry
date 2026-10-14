-- teez webdriverio adapter

local WDIO_CONFIG_CANDIDATES = {
    "wdio.conf.ts",
    "wdio.conf.js",
    "wdio.conf.mjs",
    "wdio.conf.cjs",
}

local parse_context = {
    root = ".",
    file = nil,
    suite_stack = {},
}

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

local function normalize_path(value)
    return value:gsub("\\", "/")
end

local function relative_test_path(root, absolute_path)
    local normalized_root = normalize_path(root):gsub("/+$", "")
    local normalized_path = normalize_path(absolute_path)
    local prefix = normalized_root .. "/"
    if normalized_path:sub(1, #prefix) == prefix then
        return normalized_path:sub(#prefix + 1)
    end
    if normalized_path:sub(1, 1) ~= "/" then
        return normalized_path
    end
    return normalized_path:match("([^/]+%.[%w]+)$") or normalized_path
end

local function default_include_patterns()
    return {
        "test/**/*.js",
        "test/**/*.mjs",
        "test/**/*.cjs",
        "test/**/*.ts",
        "tests/**/*.js",
        "tests/**/*.mjs",
        "tests/**/*.cjs",
        "tests/**/*.ts",
        "**/*.spec.js",
        "**/*.spec.ts",
        "**/*.e2e.js",
        "**/*.e2e.ts",
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
            if context.runner and context.runner.exclude then
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

local function resolve_wdio_config(context)
    local root = target_path(context)

    if context.runner and context.runner.config then
        return context.runner.config
    end

    if context.anchor then
        return relative_test_path(root, context.anchor)
    end

    if context.anchor_path then
        return relative_test_path(root, context.anchor_path)
    end

    for _, name in ipairs(WDIO_CONFIG_CANDIDATES) do
        for _, hit in ipairs(fs.glob(root, name)) do
            return relative_test_path(root, resolve_glob_hit(root, hit))
        end
    end

    return "wdio.conf.ts"
end

local function wdio_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function wdio_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "wdio", "run" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "--mochaOpts.grep")
        table.insert(args, context.runner.pattern)
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
        if path ~= target and path:match("%.[%w]+$") then
            table.insert(specs, relative_test_path(target, path))
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

local function build_wdio_args(context, extra)
    local args = wdio_prefix_args(context)
    table.insert(args, resolve_wdio_config(context))
    if extra then
        for _, token in ipairs(extra) do
            table.insert(args, token)
        end
    end
    append_runner_args(args, context)
    return args
end

local function join_id(parts)
    return table.concat(parts, " > ")
end

local function extract_json_payload(output, opener)
    local start = output:find(opener, 1, true)
    if not start then
        return nil
    end
    return output:sub(start)
end

local function list_entry_id(root, entry)
    local rel = relative_test_path(root, entry.file)
    local full_title = entry.fullTitle or entry.title or ""
    if full_title == "" then
        return rel
    end
    return rel .. " > " .. trim(full_title):gsub("%s+", " > ")
end

local function collect_tests_from_dry_run_json(context, output)
    local payload = extract_json_payload(output, "{")
    if not payload then
        return {}
    end

    local ok, data = pcall(json.decode, payload)
    if not ok or type(data) ~= "table" then
        return {}
    end

    local tests = {}
    local seen = {}
    local root = target_path(context)

    local function add_entry(entry)
        if type(entry) ~= "table" or not entry.file then
            return
        end
        local id = list_entry_id(root, entry)
        if not seen[id] then
            seen[id] = true
            table.insert(tests, id)
        end
    end

    for _, entry in ipairs(data.tests or {}) do
        add_entry(entry)
    end
    for _, entry in ipairs(data.pending or {}) do
        add_entry(entry)
    end

    table.sort(tests)
    return tests
end

local function strip_preface(line)
    local stripped = line:match("^%[[^%]]+%]%s*(.*)$")
    if stripped then
        return stripped
    end
    return line
end

local function collect_tests_from_dry_run_spec(context, output)
    local tests = {}
    local root = target_path(context)
    local file = nil
    local suite_stack = {}

    for line in output:gmatch("[^\r\n]+") do
        line = trim(strip_preface(line))
        if line == "" then
            goto continue
        end

        local spec_file = line:match("^»%s+(.+)$")
        if spec_file then
            file = relative_test_path(root, trim(spec_file))
            suite_stack = {}
            goto continue
        end

        local pass_title = line:match("^[✓✔]%s+(.+)$")
        local fail_title = line:match("^[✖×xX]%s+(.+)$")
        local skip_title = line:match("^%-%s+(.+)$")
        local pending_title = line:match("^[?]%s+(.+)$")
        local title = pass_title or fail_title or skip_title or pending_title

        if title and file then
            local parts = { file }
            for _, suite in ipairs(suite_stack) do
                table.insert(parts, suite)
            end
            table.insert(parts, trim(title))
            table.insert(tests, join_id(parts))
            goto continue
        end

        if file and not line:match("^%d+ passing")
            and not line:match("^%d+ failing")
            and not line:match("^%d+ skipped")
            and not line:match("^%d+ pending")
            and not line:match("^Spec Files:")
            and not line:match("^RUNNING in ")
            and not line:match("^%d+%)") then
            suite_stack = { line }
        end

        ::continue::
    end

    table.sort(tests)
    return tests
end

local function collect_tests_from_glob(context)
    local tests = {}
    local root = target_path(context)
    for _, target in ipairs(runner_targets(context)) do
        if target ~= root then
            table.insert(tests, relative_test_path(root, target))
        end
    end
    table.sort(tests)
    return tests
end

local function collect_tests(context)
    local dry_run_args = build_wdio_args(context, {
        "--spec",
        "none",
        "--reporters",
        "spec",
        "--mochaOpts.dryRun",
    })
    local output = sys.exec(wdio_command(context), dry_run_args)
    local tests = collect_tests_from_dry_run_spec(context, output)
    if #tests > 0 then
        return tests
    end

    dry_run_args = build_wdio_args(context, {
        "--spec",
        "none",
        "--mochaOpts.dryRun",
        "--mochaOpts.reporter",
        "json",
    })
    output = sys.exec(wdio_command(context), dry_run_args)
    tests = collect_tests_from_dry_run_json(context, output)
    if #tests > 0 then
        return tests
    end

    return collect_tests_from_glob(context)
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
        tool = "nyc",
        reports_directory = "coverage",
        report = "coverage/lcov.info",
        output = "coverage/teez.msgpack",
        reporter = "msgpack",
    }
end

local function effective_coverage_cfg(context)
    return shallow_merge(default_coverage_cfg(context), coverage_cfg(context))
end

local function reset_parse_context(context)
    parse_context.root = target_path(context)
    parse_context.file = nil
    parse_context.suite_stack = {}

    local specs = spec_targets(context)
    if #specs == 1 then
        parse_context.file = specs[1]
    end
end

local function build_test_id(file, suite_parts, title)
    local parts = {}
    if file and file ~= "" then
        table.insert(parts, file)
    end
    for _, part in ipairs(suite_parts) do
        table.insert(parts, part)
    end
    table.insert(parts, title)
    return join_id(parts)
end

local function looks_like_test_id(id)
    if id:match("%.[A-Za-z0-9]+%s*>") then
        return true
    end
    return id:match(">.+") ~= nil
end

local function with_duration(event, duration_ms)
    if duration_ms ~= nil then
        event.duration_ms = duration_ms
    end
    return event
end

local function split_result_tail(tail)
    local duration_ms = tail:match("(%d+)ms$")
    if duration_ms then
        local id = trim(tail:gsub("%s+%(%d+ms%)$", ""))
        return id, tonumber(duration_ms)
    end
    return trim(tail), nil
end

local function is_summary_line(line)
    return line:match("^%d+ passing")
        or line:match("^%d+ failing")
        or line:match("^%d+ skipped")
        or line:match("^%d+ pending")
        or line:match("^%d+ retried")
        or line:match("^Spec Files:")
        or line:match("^RUNNING in ")
end

local function update_suite_stack(line)
    if line:match("^»%s+") then
        return
    end
    if line:match("^[✓✔✖×xX%-?]%s+") then
        return
    end
    if line:match("^%d+%)") then
        return
    end
    if is_summary_line(line) then
        return
    end

    local title = trim(line)
    if title == "" then
        return
    end

    parse_context.suite_stack = { title }
end

local function current_suite_parts()
    local parts = {}
    for _, part in ipairs(parse_context.suite_stack) do
        table.insert(parts, part)
    end
    return parts
end

local function coverage_tool_prefix(context, cov)
    if context.runner and context.runner.coverage and context.runner.coverage.command then
        return context.runner.coverage.command, {}
    end

    local tool = cov.tool or cov.provider or "nyc"
    local reports_directory = cov.reports_directory or "coverage"
    if tool == "c8" then
        return "npx", {
            "c8",
            "--reporter=lcov",
            "--reports-dir=" .. reports_directory,
            "wdio",
            "run",
        }
    end

    return "npx", {
        "nyc",
        "--reporter=lcov",
        "--report-dir=" .. reports_directory,
        "wdio",
        "run",
    }
end

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    reset_parse_context(context)

    local args = build_wdio_args(context, { "--reporters", "spec" })
    append_spec_targets(args, context)

    return {
        command = wdio_command(context),
        args = args,
    }
end

function build_list_command(context)
    local args = build_wdio_args(context, {
        "--spec",
        "none",
        "--reporters",
        "spec",
        "--mochaOpts.dryRun",
    })
    return {
        command = wdio_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local command, prefix_args = coverage_tool_prefix(context, cov)
    local args = prefix_args
    table.insert(args, resolve_wdio_config(context))
    table.insert(args, "--reporters")
    table.insert(args, "spec")
    append_runner_args(args, context)
    append_spec_targets(args, context)

    return {
        command = command,
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
        note = "Best-effort nyc/c8 wrapper; instrument app code and configure wdio-coverage-service or monocart for reliable LCOV",
    }
end

function parse_line(line)
    line = strip_preface(line)

    if line:match("^%s*→%s+") then
        return nil
    end
    if is_summary_line(line) then
        return nil
    end
    if line:match("^%s*Error:") or line:match("^%s*at%s+") then
        return nil
    end

    local spec_file = line:match("^»%s+(.+)$")
    if spec_file then
        parse_context.file = relative_test_path(parse_context.root, trim(spec_file))
        parse_context.suite_stack = {}
        return nil
    end

    update_suite_stack(line)

    local pass_tail = line:match("^%s*[✓✔]%s+(.+)$")
    if pass_tail then
        local title, duration_ms = split_result_tail(pass_tail)
        local id = build_test_id(parse_context.file, current_suite_parts(), title)
        if not looks_like_test_id(id) then
            return nil
        end
        return with_duration({ event = "pass", id = id }, duration_ms)
    end

    local fail_tail = line:match("^%s*[✖×xX]%s+(.+)$") or line:match("^%s*%d+%)%s+(.+)$")
    if fail_tail then
        local title, duration_ms = split_result_tail(fail_tail)
        local id = build_test_id(parse_context.file, current_suite_parts(), title)
        if not looks_like_test_id(id) then
            return nil
        end
        return with_duration({ event = "fail", id = id, msg = "FAILED" }, duration_ms)
    end

    local skip_tail = line:match("^%s*%-%s+(.+)$")
    if skip_tail then
        local title, duration_ms = split_result_tail(skip_tail)
        local id = build_test_id(parse_context.file, current_suite_parts(), title)
        if not looks_like_test_id(id) then
            return nil
        end
        return with_duration({ event = "skip", id = id }, duration_ms)
    end

    local pending_tail = line:match("^%s*%?%s+(.+)$")
    if pending_tail then
        local title, duration_ms = split_result_tail(pending_tail)
        local id = build_test_id(parse_context.file, current_suite_parts(), title)
        if not looks_like_test_id(id) then
            return nil
        end
        return with_duration({ event = "todo", id = id }, duration_ms)
    end

    return nil
end
