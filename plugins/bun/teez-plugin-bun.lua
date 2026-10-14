-- teez bun test adapter

local parse_context = {
    file = nil,
}

local help_cache = nil

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

local function bun_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "bun"
end

local function bun_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "test" }
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

local function build_bun_args(context, extra)
    local args = bun_prefix_args(context)
    if extra then
        for _, token in ipairs(extra) do
            table.insert(args, token)
        end
    end
    append_runner_args(args, context)
    return args
end

local function join_titles(parts)
    return table.concat(parts, " > ")
end

local function bun_test_help(context)
    if help_cache then
        return help_cache
    end
    help_cache = sys.exec(bun_command(context or {}), { "test", "--help" }) or ""
    return help_cache
end

local function flag_supported(context, flag_pattern)
    return bun_test_help(context):match(flag_pattern) ~= nil
end

local function dry_run_supported(context)
    return flag_supported(context, "%-%-dry%-run")
end

local function coverage_supported(context)
    return flag_supported(context, "%-%-coverage")
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

local function parse_file_header(line)
    local file = line:match("^(%S+%.[jt]sx?):$")
    if file then
        return file
    end
    return nil
end

local function parse_result_line(line)
    local matchers = {
        { "^%(pass%)%s+(.+)$", "pass" },
        { "^%(fail%)%s+(.+)$", "fail" },
        { "^%(skip%)%s+(.+)$", "skip" },
        { "^%(todo%)%s+(.+)$", "todo" },
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
    local duration_ms = tail:match("%[(%d+%.?%d*)ms%]$")
    local name = tail
    if duration_ms then
        name = trim(tail:gsub("%s*%[%d+%.?%d*ms%]$", ""))
        duration_ms = tonumber(duration_ms)
    end
    return trim(name), duration_ms
end

local function build_test_id(file, title)
    if file and file ~= "" then
        return join_titles({ file, title })
    end
    return title
end

local function collect_tests_from_dry_run(context, output)
    local tests = {}
    local seen = {}
    local current_file = nil

    for line in output:gmatch("[^\r\n]+") do
        line = trim(line)
        if line == "" then
            goto continue
        end

        local file = parse_file_header(line)
        if file then
            current_file = file
            goto continue
        end

        local status, tail = parse_result_line(line)
        if status and tail then
            local title = split_result_tail(tail)
            local id = build_test_id(current_file, title)
            if not seen[id] then
                seen[id] = true
                table.insert(tests, id)
            end
        end

        ::continue::
    end

    table.sort(tests)
    return tests
end

local function collect_tests_with_dry_run(context)
    local args = build_bun_args(context, { "--dry-run" })
    append_targets(args, context)

    local output = sys.exec(bun_command(context), args)
    if not output or output == "" then
        return {}
    end

    local tests = collect_tests_from_dry_run(context, output)
    if #tests > 0 then
        return tests
    end

    return {}
end

local function collect_tests(context)
    if dry_run_supported(context) then
        local dry_run_tests = collect_tests_with_dry_run(context)
        if #dry_run_tests > 0 then
            return dry_run_tests
        end
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
    if id:match("%.[A-Za-z0-9]+%s*>") then
        return true
    end
    return id:match("%.[A-Za-z0-9]+$") ~= nil
end

local function with_duration(event, duration_ms)
    if duration_ms ~= nil then
        event.duration_ms = duration_ms
    end
    return event
end

local function should_ignore_line(line)
    if line:match("^bun test v") then
        return true
    end
    if line:match("^%s*at%s+") or line:match("^%s*error:") then
        return true
    end
    if line:match("^%s*Expected") or line:match("^%s*Received") then
        return true
    end
    if line:match("^%s*%d+%s*|") then
        return true
    end
    if line:match("^%d+ pass") or line:match("^%d+ fail") or line:match("^%d+ skip") or line:match("^%d+ todo") then
        return true
    end
    if line:match("^%d+ expect%(%) calls") then
        return true
    end
    if line:match("^Ran %d+ tests") then
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
    parse_context.file = nil

    local args = build_bun_args(context, nil)
    append_targets(args, context)

    return {
        command = bun_command(context),
        args = args,
    }
end

function build_list_command(context)
    if dry_run_supported(context) then
        local args = build_bun_args(context, { "--dry-run" })
        append_targets(args, context)
        return {
            command = bun_command(context),
            args = args,
        }
    end

    return nil
end

function build_coverage_run(context)
    if not coverage_supported(context) then
        return nil
    end

    parse_context.file = nil

    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local args = build_bun_args(context, {
        "--coverage",
        "--coverage-reporter=lcov",
        "--coverage-dir=" .. reports_directory,
    })
    append_targets(args, context)

    return {
        command = bun_command(context),
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
    }
end

function parse_line(line)
    line = trim(line)
    if line == "" or should_ignore_line(line) then
        return nil
    end

    local file = parse_file_header(line)
    if file then
        parse_context.file = file
        return nil
    end

    local status, tail = parse_result_line(line)
    if not status or not tail then
        return nil
    end

    local title, duration_ms = split_result_tail(tail)
    local id = build_test_id(parse_context.file, title)
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
