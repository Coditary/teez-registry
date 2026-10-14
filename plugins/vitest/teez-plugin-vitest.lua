-- teez vitest adapter

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

local function runner_targets(context)
    local target = target_path(context)
    if not context.runner or not context.runner.include then
        return { target }
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
        return { target }
    end
    return paths
end

local function vitest_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function vitest_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "vitest" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "-t")
        table.insert(args, context.runner.pattern)
    end

    if context.runner.args then
        for _, arg in ipairs(context.runner.args) do
            table.insert(args, arg)
        end
    end
end

local function append_targets(args, context)
    for _, target in ipairs(runner_targets(context)) do
        table.insert(args, target)
    end
end

local function build_vitest_args(context, subcommand, extra)
    local args = vitest_prefix_args(context)
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
    local prefix = normalized_root .. "/"
    if normalized_path:sub(1, #prefix) == prefix then
        return normalized_path:sub(#prefix + 1)
    end
    return normalized_path:match("([^/]+%.[%w]+)$") or normalized_path
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
    return rel .. " > " .. entry.name
end

local function collect_tests_from_list_json(context, output)
    local payload = extract_json_payload(output, "[")
    if not payload then
        return {}
    end

    local entries = json.decode(payload)
    local tests = {}
    local root = target_path(context)
    for _, entry in ipairs(entries) do
        table.insert(tests, list_entry_id(root, entry))
    end
    table.sort(tests)
    return tests
end

local function collect_tests_plain(context)
    local tests = {}
    for _, target in ipairs(runner_targets(context)) do
        local args = build_vitest_args(context, { "list" }, nil)
        table.insert(args, target)

        local output = sys.exec(vitest_command(context), args)
        for line in output:gmatch("[^\r\n]+") do
            line = trim(line)
            if line ~= "" then
                table.insert(tests, line)
            end
        end
    end
    table.sort(tests)
    return tests
end

local function collect_tests(context)
    local args = build_vitest_args(context, { "list" }, { "--json" })
    append_targets(args, context)

    local output = sys.exec(vitest_command(context), args)
    local tests = collect_tests_from_list_json(context, output)
    if #tests > 0 then
        return tests
    end

    return collect_tests_plain(context)
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
        provider = "v8",
        reports_directory = "coverage",
        report = "coverage/lcov.info",
        output = "coverage/teez.msgpack",
        reporter = "msgpack",
    }
end

local function effective_coverage_cfg(context)
    return shallow_merge(default_coverage_cfg(context), coverage_cfg(context))
end

local function looks_like_test_id(id)
    return id:match("%.[A-Za-z0-9]+%s*>") ~= nil
end

local function match_result_line(line)
    local matchers = {
        { "^%s*✓%s+(.+)$", "pass" },
        { "^%s*✔%s+(.+)$", "pass" },
        { "^%s*×%s+(.+)$", "fail" },
        { "^%s*x%s+(.+)$", "fail" },
        { "^%s*X%s+(.+)$", "fail" },
        { "^%s*↓%s+(.+)$", "skip" },
        { "^%s*□%s+(.+)$", "todo" },
    }

    for _, matcher in ipairs(matchers) do
        local tail = line:match(matcher[1])
        if tail then
            return matcher[2], tail
        end
    end

    return nil, nil
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

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    local args = build_vitest_args(context, { "run" }, { "--reporter=verbose" })
    append_targets(args, context)

    return {
        command = vitest_command(context),
        args = args,
    }
end

function build_list_command(context)
    local args = build_vitest_args(context, { "list" }, nil)
    append_targets(args, context)
    return {
        command = vitest_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local args = build_vitest_args(context, { "run" }, {
        "--coverage",
        "--coverage.provider=" .. (cov.provider or "v8"),
        "--coverage.reporter=lcov",
        "--coverage.reportsDirectory=" .. reports_directory,
    })
    append_targets(args, context)

    return {
        command = vitest_command(context),
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
    }
end

function parse_line(line)
    if line:match("^%s*→%s+") then
        return nil
    end

    local status, tail = match_result_line(line)
    if not status or not tail then
        return nil
    end

    local id, duration_ms = split_result_tail(tail)
    if not looks_like_test_id(id) then
        return nil
    end

    if status == "pass" then
        return with_duration({ event = "pass", id = id }, duration_ms)
    end

    if status == "fail" then
        return with_duration({ event = "fail", id = id, msg = "FAILED" }, duration_ms)
    end

    if status == "todo" then
        return with_duration({ event = "todo", id = id }, duration_ms)
    end

    return with_duration({ event = "skip", id = id }, duration_ms)
end
