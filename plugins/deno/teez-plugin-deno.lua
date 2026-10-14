-- teez deno test adapter

local parse_context = {
    file = nil,
    pending_suite = nil,
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

local function deno_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "deno"
end

local function deno_prefix_args(context)
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
        table.insert(args, "--filter")
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

local function build_deno_args(context, extra)
    local args = deno_prefix_args(context)
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

local function deno_test_help(context)
    if help_cache then
        return help_cache
    end
    help_cache = sys.exec(deno_command(context or {}), { "test", "--help" }) or ""
    return help_cache
end

local function flag_supported(context, flag_pattern)
    return deno_test_help(context):match(flag_pattern) ~= nil
end

local function list_supported(context)
    return flag_supported(context, "%-%-list")
end

local function coverage_supported(context)
    return flag_supported(context, "%-%-coverage")
end

local function push_suite(stack, name)
    table.insert(stack, name)
end

local function pop_suite(stack)
    if #stack > 0 then
        table.remove(stack)
    end
end

local function make_test_id(rel_file, suite_stack, name)
    local parts = { rel_file }
    for _, suite in ipairs(suite_stack) do
        table.insert(parts, suite)
    end
    table.insert(parts, name)
    return join_titles(parts)
end

local function tap_file_path(line)
    local file = line:match("^#%s+%./(.+)$")
    if file then
        return file
    end
    return line:match("^#%s+(.+)$")
end

local function subtest_indent(line)
    local indent = line:match("^(%s*)# Subtest:")
    if not indent then
        return nil
    end
    return #indent
end

local function is_suite_subtest(lines, index)
    local subtest = lines[index]:match("^# Subtest: (.+)$")
    if not subtest or (subtest_indent(lines[index]) or 0) ~= 0 then
        return false
    end

    local peek = index + 1
    while peek <= #lines do
        local line = lines[peek]
        if line:match("^%s+# Subtest:") or line:match("^%s+ok ") or line:match("^%s+not ok ") then
            return true
        end
        if line:match("^ok ") or line:match("^not ok ") then
            return false
        end
        peek = peek + 1
    end

    return false
end

local function collect_tests_from_tap_output(context, output, rel_file)
    local tests = {}
    local suite_stack = {}
    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local index = 1
    while index <= #lines do
        local line = lines[index]
        local file = tap_file_path(line)
        if file then
            rel_file = relative_test_path(target_path(context), file)
            index = index + 1
        else
            local subtest = line:match("^# Subtest: (.+)$")
            if subtest and is_suite_subtest(lines, index) then
                push_suite(suite_stack, trim(subtest))
                index = index + 1
            else
                local status, name = line:match("^(ok) %d+ %- (.+)$")
                if not status then
                    status, name = line:match("^(not ok) %d+ %- (.+)$")
                end
                if status and name then
                    name = trim(name:gsub(" # SKIP$", ""):gsub(" # TODO$", ""))
                    local indent = line:match("^(%s*)ok ") or line:match("^(%s*)not ok ") or ""
                    if indent == "" and #suite_stack > 0 and suite_stack[#suite_stack] == name then
                        table.insert(tests, make_test_id(rel_file, {}, name))
                        pop_suite(suite_stack)
                    else
                        table.insert(tests, make_test_id(rel_file, suite_stack, name))
                    end
                end
                index = index + 1
            end
        end
    end

    table.sort(tests)
    return tests
end

local function collect_tests_from_list_output(context, output)
    local tests = {}
    local root = target_path(context)
    local seen = {}

    for line in output:gmatch("[^\r\n]+") do
        line = trim(line)
        if line == "" or line:match("^TAP version") or line:match("^Check ") then
            goto continue
        end

        local id = line
        if not line:match("%s*>%s*") and line:match("%.[A-Za-z0-9]+$") then
            id = relative_test_path(root, line)
        end

        if not seen[id] then
            seen[id] = true
            table.insert(tests, id)
        end

        ::continue::
    end

    table.sort(tests)
    return tests
end

local function collect_tests_with_list(context)
    local args = build_deno_args(context, { "--list" })
    append_targets(args, context)

    local output = sys.exec(deno_command(context), args)
    if not output or output == "" then
        return {}
    end

    return collect_tests_from_list_output(context, output)
end

local function collect_tests_for_target(context, target)
    local rel_file = relative_test_path(target_path(context), target)
    local args = build_deno_args(context, { "--reporter=tap", target })
    local output = sys.exec(deno_command(context), args)
    return collect_tests_from_tap_output(context, output, rel_file)
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
    if list_supported(context) then
        local list_tests = collect_tests_with_list(context)
        if #list_tests > 0 then
            return list_tests
        end
    end

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

local function parse_duration(value)
    if not value then
        return nil
    end
    local ms = value:match("^(%d+%.?%d*)ms$")
    if ms then
        return tonumber(ms)
    end
    local us = value:match("^(%d+%.?%d*)[µμ]s$")
    if us then
        return tonumber(us) / 1000
    end
    return nil
end

local function split_result_line(line)
    local indent, name, status, duration = line:match("^(%s*)(.-) %.%.%.%s+(ok|FAILED|ignored)(?: %((.+)%))?$")
    if not name or not status then
        return nil, nil, nil, nil
    end
    return indent or "", trim(name), status, parse_duration(duration)
end

local function build_test_id(file, suite, title)
    local parts = { file }
    if suite and suite ~= "" then
        table.insert(parts, suite)
    end
    table.insert(parts, title)
    return join_titles(parts)
end

local function parse_running_file(line)
    local file = line:match("^running %d+ tests? from %./(.+)$")
    if file then
        return file
    end
    return line:match("^running %d+ tests? from (.+)$")
end

local function should_ignore_line(line)
    if line:match("^Check ") then
        return true
    end
    if line:match("^%s*ERRORS%s*$") or line:match("^%s*FAILURES%s*$") then
        return true
    end
    if line:match("^%s*error:") or line:match("^%s*at ") then
        return true
    end
    if line:match("^%s*=> %./") or line:match("^%s*=> ") then
        return true
    end
    if line:match("^%s*FAILED%s*|") or line:match("^%s*ok%s*|") then
        return true
    end
    if line:match("^%s*error: Test failed") then
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
    parse_context.pending_suite = nil

    local args = build_deno_args(context, nil)
    append_targets(args, context)

    return {
        command = deno_command(context),
        args = args,
    }
end

function build_list_command(context)
    if list_supported(context) then
        local args = build_deno_args(context, { "--list" })
        append_targets(args, context)
        return {
            command = deno_command(context),
            args = args,
        }
    end

    local args = build_deno_args(context, { "--reporter=tap" })
    append_targets(args, context)
    return {
        command = deno_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    if not coverage_supported(context) then
        return nil
    end

    parse_context.file = nil
    parse_context.pending_suite = nil

    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local args = build_deno_args(context, {
        "--coverage=" .. reports_directory,
    })
    append_targets(args, context)

    return {
        command = deno_command(context),
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
    }
end

function parse_line(line)
    line = trim(line:gsub("%c%[[%d;]*m", ""))
    if line == "" or should_ignore_line(line) then
        return nil
    end

    local running_file = parse_running_file(line)
    if running_file then
        parse_context.file = running_file
        parse_context.pending_suite = nil
        return nil
    end

    local indent, name, status, duration_ms = split_result_line(line)
    if not name or not status then
        if line:match(" %.%.%.$") then
            local pending = trim(line:gsub(" %.%.%.$", ""))
            if pending ~= "" then
                parse_context.pending_suite = pending
            end
        end
        return nil
    end

    if not parse_context.file then
        return nil
    end

    local rel_file = parse_context.file
    if rel_file:sub(1, 2) == "./" then
        rel_file = rel_file:sub(3)
    end

    local suite = nil
    if indent ~= "" and parse_context.pending_suite then
        suite = parse_context.pending_suite
    end

    local id = build_test_id(rel_file, suite, name)
    if not looks_like_test_id(id) then
        return nil
    end

    if indent == "" and parse_context.pending_suite == name then
        parse_context.pending_suite = nil
    end

    if status == "ok" then
        return with_duration({ event = "pass", id = id }, duration_ms)
    end

    if status == "FAILED" then
        return with_duration({ event = "fail", id = id, msg = "FAILED" }, duration_ms)
    end

    if status == "ignored" then
        return with_duration({ event = "skip", id = id }, duration_ms)
    end

    return nil
end
