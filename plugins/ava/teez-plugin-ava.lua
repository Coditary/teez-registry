-- teez ava adapter

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

local function ava_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function ava_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "ava" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "--match")
        table.insert(args, context.runner.pattern)
    end

    if context.runner.args then
        for _, arg in ipairs(context.runner.args) do
            table.insert(args, arg)
        end
    end
end

local function build_ava_args(context, extra)
    local args = ava_prefix_args(context)
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

local function join_titles(parts)
    return table.concat(parts, " > ")
end

local function normalize_ava_title(title)
    return trim(title):gsub(" › ", " > ")
end

local function build_test_id(file, title)
    title = normalize_ava_title(title)
    if file and file ~= "" then
        return join_titles({ file, title })
    end
    return title
end

local function extract_fail_title(tail)
    tail = trim(tail)
    local title = tail:match("^(.-)%s+Test failed")
    if title then
        return trim(title)
    end
    title = tail:match("^(.-)%s+Rejected promise")
    if title then
        return trim(title)
    end
    return tail
end

local function split_result_tail(tail)
    local duration_s = tail:match("%((%d+%.?%d*)s%)$")
    if duration_s then
        local name = trim(tail:gsub("%s*%(%d+%.?%d*s%)$", ""))
        return name, tonumber(duration_s) * 1000
    end

    local duration_ms = tail:match("(%d+)ms$")
    if duration_ms then
        local name = trim(tail:gsub("%s+%d+ms$", ""))
        return name, tonumber(duration_ms)
    end

    return trim(tail), nil
end

local function parse_verbose_result_line(line)
    local title = line:match("^%s*✔%s+(.+)$")
    if title then
        return "pass", title
    end

    title = line:match("^%s*✘%s+%[fail%]:%s*(.+)$")
    if title then
        return "fail", extract_fail_title(title)
    end

    title = line:match("^%s*-%s+%[skip%]%s+(.+)$")
    if title then
        return "skip", title
    end

    title = line:match("^%s*◌%s+(.+)$")
    if title then
        return "skip", title
    end

    return nil, nil
end

local function collect_tests_from_verbose_output(context, output, file)
    local tests = {}
    local seen = {}
    local root = target_path(context)

    for line in output:gmatch("[^\r\n]+") do
        local _, title = parse_verbose_result_line(line)
        if title then
            local rel_file = file
            if not rel_file and title:find(" > ") then
                rel_file = nil
            end
            local id = build_test_id(rel_file, title)
            if not seen[id] then
                seen[id] = true
                table.insert(tests, id)
            end
        end
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

local function dry_run_unavailable(output)
    if not output then
        return true
    end
    return output:match("Unknown flag") ~= nil
        or output:match("unknown option") ~= nil
        or output:match("Couldn't find any files to test") ~= nil
end

local function collect_tests_for_target(context, target)
    local root = target_path(context)
    local rel_file = relative_test_path(root, target)
    local args = build_ava_args(context, { "--verbose", "--dry-run", rel_file })

    local output = sys.exec(ava_command(context), args)
    if dry_run_unavailable(output) then
        return {}
    end

    return collect_tests_from_verbose_output(context, output, rel_file)
end

local function collect_tests(context)
    local tests = {}
    local seen = {}
    for _, target in ipairs(runner_targets(context)) do
        for _, test_id in ipairs(collect_tests_for_target(context, target)) do
            if not seen[test_id] then
                seen[test_id] = true
                table.insert(tests, test_id)
            end
        end
    end

    if #tests > 0 then
        table.sort(tests)
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
        tool = "c8",
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
}

local function reset_parse_context(context)
    parse_context.root = target_path(context)
    parse_context.file = nil

    local targets = runner_targets(context)
    if #targets == 1 and targets[1]:match("%.[A-Za-z0-9]+$") then
        parse_context.file = relative_test_path(parse_context.root, targets[1])
    end
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

local function maybe_set_file_from_location(line)
    local file = line:match("^%s*([%w%./_-]+%.%w+):%d+%s*$")
    if file then
        parse_context.file = relative_test_path(parse_context.root, file)
    end
end

local function should_ignore_line(line)
    line = trim(line)
    if line == "" then
        return true
    end
    if line:match("^%s*→%s+") then
        return true
    end
    if line:match("^%s*─") or line == "─" then
        return true
    end
    if line:match("^%d+ tests? passed") or line:match("^%d+ tests? failed") or line:match("^%d+ tests? skipped") then
        return true
    end
    if line:match("^%s*at%s+") then
        return true
    end
    if line:match("^%s*AssertionError") or line:match("^%s*Error:") then
        return true
    end
    if line:match("^%s*Expected") or line:match("^%s*Received") then
        return true
    end
    if line:match("^%s*Timed out while running tests") then
        return true
    end
    if line:match("^%s*✘%s+Couldn't find any files to test") then
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
    reset_parse_context(context)

    local args = build_ava_args(context, { "--verbose" })
    append_targets(args, context)

    return {
        command = ava_command(context),
        args = args,
    }
end

function build_list_command(context)
    local args = build_ava_args(context, { "--verbose", "--dry-run" })
    append_targets(args, context)

    return {
        command = ava_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    reset_parse_context(context)

    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local args = {
        "c8",
        "--reporter=lcov",
        "--reports-dir=" .. reports_directory,
        "ava",
        "--verbose",
    }
    append_runner_args(args, context)
    append_targets(args, context)

    return {
        command = "npx",
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
        maybe_set_file_from_location(line)
        return nil
    end

    maybe_set_file_from_location(line)

    local status, title = parse_verbose_result_line(line)
    if not status or not title then
        return nil
    end

    local test_title, duration_ms = split_result_tail(title)
    local id = build_test_id(parse_context.file, test_title)
    if not looks_like_test_id(id) then
        return nil
    end

    if status == "pass" then
        return with_duration({ event = "pass", id = id }, duration_ms)
    end

    if status == "fail" then
        return with_duration({ event = "fail", id = id, msg = "FAILED" }, duration_ms)
    end

    return with_duration({ event = "skip", id = id }, duration_ms)
end
