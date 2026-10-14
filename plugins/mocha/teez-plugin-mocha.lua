-- teez mocha adapter

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

local function default_mocha_targets(context)
    local target = target_path(context)
    local patterns = {
        "test/**/*.js",
        "test/**/*.mjs",
        "test/**/*.cjs",
        "tests/**/*.js",
        "tests/**/*.mjs",
        "tests/**/*.cjs",
        "**/*.test.js",
        "**/*.spec.js",
    }
    local paths = {}
    local seen = {}
    for _, pattern in ipairs(patterns) do
        for _, file in ipairs(fs.glob(target, pattern)) do
            local resolved = resolve_glob_hit(target, file)
            if not seen[resolved] then
                seen[resolved] = true
                table.insert(paths, resolved)
            end
        end
    end
    if #paths > 0 then
        return paths
    end
    return { target }
end

local function runner_targets(context)
    local target = target_path(context)
    if not context.runner or not context.runner.include then
        return default_mocha_targets(context)
    end

    local paths = {}
    local seen = {}
    for _, pattern in ipairs(context.runner.include) do
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
        return default_mocha_targets(context)
    end
    return paths
end

local function mocha_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function mocha_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "mocha" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "--grep")
        table.insert(args, context.runner.pattern)
    end

    if context.runner.args then
        for _, arg in ipairs(context.runner.args) do
            table.insert(args, arg)
        end
    end
end

local function build_mocha_args(context, extra)
    local args = mocha_prefix_args(context)
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
    local prefix = normalized_root .. "/"
    if normalized_path:sub(1, #prefix) == prefix then
        return normalized_path:sub(#prefix + 1)
    end
    return normalized_path:match("([^/]+%.[%w]+)$") or normalized_path
end

local function append_targets(args, context)
    local root = target_path(context)
    for _, target in ipairs(runner_targets(context)) do
        table.insert(args, relative_test_path(root, target))
    end
end

local function extract_json_payload(output, opener)
    local start = output:find(opener, 1, true)
    if not start then
        return nil
    end
    return output:sub(start)
end

local function join_titles(parts)
    return table.concat(parts, " > ")
end

local function full_title_id(full_title)
    return trim(full_title):gsub("%s+", " > ")
end

local function list_entry_id(root, entry)
    local rel = relative_test_path(root, entry.file)
    local full_title = entry.fullTitle or entry.title or ""
    if full_title == "" then
        return rel
    end
    return rel .. " > " .. full_title_id(full_title)
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

local function collect_tests_from_glob(context)
    local tests = {}
    local root = target_path(context)
    for _, target in ipairs(runner_targets(context)) do
        table.insert(tests, relative_test_path(root, target))
    end
    table.sort(tests)
    return tests
end

local function collect_tests(context)
    local args = build_mocha_args(context, { "--dry-run", "--reporter", "json" })
    append_targets(args, context)

    local output = sys.exec(mocha_command(context), args)
    local tests = collect_tests_from_dry_run_json(context, output)
    if #tests > 0 then
        return tests
    end

    args = build_mocha_args(context, { "--dry-run", "--reporter", "spec" })
    append_targets(args, context)
    output = sys.exec(mocha_command(context), args)
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

local parse_context = {
    root = ".",
    file = nil,
    suite_stack = {},
}

local function reset_parse_context(context)
    parse_context.root = target_path(context)
    parse_context.file = nil
    parse_context.suite_stack = {}

    local targets = runner_targets(context)
    if #targets == 1 and targets[1]:match("%.[A-Za-z0-9]+$") then
        parse_context.file = relative_test_path(parse_context.root, targets[1])
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
    return join_titles(parts)
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

local function indent_level(line)
    local spaces = line:match("^(%s+)")
    if not spaces then
        return 0
    end
    return #spaces
end

local function is_summary_line(title)
    return title:match("^%d+ passing")
        or title:match("^%d+ pending")
        or title:match("^%d+ failing")
        or title:match("^%d+ failing")
        or title:match("^%d+%)")
end

local function is_test_result_line(line)
    return indent_level(line) >= 4 and line:match("^%s+%S+%s+%S") ~= nil
end

local function update_suite_stack(line)
    if is_test_result_line(line) then
        return
    end

    local spaces, title = line:match("^(%s+)([%S].*)$")
    if not spaces or not title then
        return
    end

    title = trim(title)
    if title == "" or is_summary_line(title) then
        return
    end
    if title:match("^AssertionError") then
        return
    end

    local level = math.floor(#spaces / 2)
    if level < 1 then
        return
    end

    while #parse_context.suite_stack >= level do
        table.remove(parse_context.suite_stack)
    end
    table.insert(parse_context.suite_stack, title)
end

local function current_suite_parts()
    local parts = {}
    for _, part in ipairs(parse_context.suite_stack) do
        table.insert(parts, part)
    end
    return parts
end

local function maybe_set_file_from_stack(line)
    local stack_file = line:match("at .+%(([^:)]+):")
    if not stack_file then
        return
    end
    parse_context.file = relative_test_path(parse_context.root, stack_file)
end

local function should_ignore_line(line)
    line = trim(line)
    if line == "" then
        return true
    end
    if line:match("^%s*→%s+") then
        return true
    end
    if line:match("^%s*%- expected") or line:match("^%s*%+ expected") or line:match("^%s*%- actual") or line:match("^%s*%+ actual") then
        return true
    end
    if line:match("^%s*%-%s+%S") and not line:match("^%s*%-%s+[%w]") then
        return true
    end
    if line:match("^%s*%+%s+%S") then
        return true
    end
    if line:match("^%s*AssertionError") then
        return true
    end
    if line:match("^%s*at%s+") then
        maybe_set_file_from_stack(line)
        return true
    end
    return false
end

local function parse_spec_result_line(line)
    local level = indent_level(line)
    if level < 4 then
        return nil, nil
    end

    local leader, title = line:match("^(%s+%S+)%s+(.+)$")
    if not leader or not title then
        return nil, nil
    end

    title = trim(title)
    if title == "" then
        return nil, nil
    end

    if leader:match("%d+%)$") then
        return "fail", title
    end

    if leader:match("%-$") then
        return "skip", title
    end

    return "pass", title
end

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    reset_parse_context(context)

    local args = build_mocha_args(context, { "--reporter", "spec" })
    append_targets(args, context)

    return {
        command = mocha_command(context),
        args = args,
    }
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
            "mocha",
        }
    end

    return "npx", {
        "nyc",
        "--reporter=lcov",
        "--report-dir=" .. reports_directory,
        "mocha",
    }
end

function build_coverage_run(context)
    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local command, prefix_args = coverage_tool_prefix(context, cov)
    local args = prefix_args
    table.insert(args, "--reporter")
    table.insert(args, "spec")
    append_runner_args(args, context)
    append_targets(args, context)

    return {
        command = command,
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
    }
end

function parse_line(line)
    if should_ignore_line(line) then
        return nil
    end

    update_suite_stack(line)

    local status, title = parse_spec_result_line(line)
    if not status or not title then
        return nil
    end

    local id = build_test_id(parse_context.file, current_suite_parts(), title)
    if not looks_like_test_id(id) then
        return nil
    end

    if status == "pass" then
        return with_duration({ event = "pass", id = id }, nil)
    end
    if status == "fail" then
        return with_duration({ event = "fail", id = id, msg = "FAILED" }, nil)
    end
    return with_duration({ event = "skip", id = id }, nil)
end
