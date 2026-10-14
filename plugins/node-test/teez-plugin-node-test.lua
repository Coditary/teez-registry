-- teez node:test adapter

local parse_state = {
    files = {},
    file_index = 1,
    current_file = nil,
    tests_remaining = 0,
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

local function node_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "node"
end

local function node_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "--test" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "--test-name-pattern=" .. context.runner.pattern)
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

local function build_node_args(context, extra)
    local args = node_prefix_args(context)
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

local function join_id(parts)
    return table.concat(parts, " > ")
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
    return join_id(parts)
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

local function subtest_indent(line)
    local indent = line:match("^(%s*)# Subtest:")
    if not indent then
        return nil
    end
    return #indent
end

local function read_yaml_type(lines, start_index)
    local index = start_index + 1
    while index <= #lines do
        local line = lines[index]
        if line:match("^ok ") or line:match("^not ok ") or line:match("^# Subtest:") then
            return nil, index - 1
        end
        local entry_type = line:match("type:%s*'([^']+)'")
        if entry_type then
            return entry_type, index
        end
        if line == "  ..." then
            return nil, index
        end
        index = index + 1
    end
    return nil, start_index
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

local function collect_tests_from_tap(context, output, rel_file)
    local tests = {}
    local suite_stack = {}
    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
        table.insert(lines, line)
    end

    local index = 1
    while index <= #lines do
        local line = lines[index]
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
                local entry_type = read_yaml_type(lines, index)
                if entry_type == "suite" then
                    if #suite_stack > 0 and suite_stack[#suite_stack] == name then
                        pop_suite(suite_stack)
                    end
                else
                    table.insert(tests, make_test_id(rel_file, suite_stack, name))
                end
            end
            index = index + 1
        end
    end

    table.sort(tests)
    return tests
end

local function collect_tests_for_target(context, target)
    local rel_file = relative_test_path(target_path(context), target)
    local args = build_node_args(context, {
        "--test-reporter=tap",
        target,
    })
    local output = sys.exec(node_command(context), args)
    return collect_tests_from_tap(context, output, rel_file)
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
    table.sort(tests)
    return tests
end

local function count_tests_per_file(context)
    local counts = {}
    for _, target in ipairs(runner_targets(context)) do
        counts[#counts + 1] = #collect_tests_for_target(context, target)
    end
    return counts
end

local function reset_parse_state(context)
    parse_state.files = {}
    parse_state.file_index = 1
    parse_state.current_file = nil
    parse_state.tests_remaining = 0
    parse_state.suite_stack = {}

    local root = target_path(context)
    for _, target in ipairs(runner_targets(context)) do
        table.insert(parse_state.files, relative_test_path(root, target))
    end

    if #parse_state.files > 0 then
        parse_state.current_file = parse_state.files[1]
    end

    local counts = count_tests_per_file(context)
    parse_state.tests_remaining = counts[1] or 0
    parse_state._counts = counts
end

local function advance_parse_file()
    if parse_state.file_index >= #parse_state.files then
        parse_state.tests_remaining = 0
        return
    end
    parse_state.file_index = parse_state.file_index + 1
    parse_state.current_file = parse_state.files[parse_state.file_index]
    parse_state.tests_remaining = parse_state._counts[parse_state.file_index] or 0
    parse_state.suite_stack = {}
end

local function consume_parse_test()
    if parse_state.tests_remaining > 0 then
        parse_state.tests_remaining = parse_state.tests_remaining - 1
    end
    if parse_state.tests_remaining == 0 then
        advance_parse_file()
    end
end

local function looks_like_test_id(id)
    return id:match("%.[A-Za-z0-9]+%s*>") ~= nil
end

local function match_result_line(line)
    local matchers = {
        { "^(%s*)✓%s+(.+)$", "pass" },
        { "^(%s*)✔%s+(.+)$", "pass" },
        { "^(%s*)×%s+(.+)$", "fail" },
        { "^(%s*)✖%s+(.+)$", "fail" },
        { "^(%s*)x%s+(.+)$", "fail" },
        { "^(%s*)X%s+(.+)$", "fail" },
        { "^(%s*)↓%s+(.+)$", "skip" },
        { "^(%s*)﹣%s+(.+)$", "skip" },
        { "^(%s*)-%s+(.+)$", "skip" },
        { "^(%s*)□%s+(.+)$", "todo" },
    }

    for _, matcher in ipairs(matchers) do
        local indent, tail = line:match(matcher[1])
        if tail then
            return matcher[2], tail, indent or ""
        end
    end

    return nil, nil, nil
end

local function split_result_tail(tail)
    local duration_ms = tail:match("(%d+%.?%d*)ms")
    local name = tail
    if duration_ms then
        name = trim(tail:gsub("%s+%d+%.?%d*ms$", ""))
        duration_ms = tonumber(duration_ms)
    end
    name = trim(name:gsub(" # SKIP$", ""):gsub(" # TODO$", ""))
    return name, duration_ms
end

local function with_duration(event, duration_ms)
    if duration_ms ~= nil then
        event.duration_ms = duration_ms
    end
    return event
end

local function current_test_id(name)
    if not parse_state.current_file then
        return nil
    end
    return make_test_id(parse_state.current_file, parse_state.suite_stack, name)
end

local function update_current_file_from_failure(line)
    local file = line:match("^test at ([^:]+):")
    if file then
        parse_state.current_file = file
    end
end

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    reset_parse_state(context)

    local args = build_node_args(context, {
        "--test-reporter=spec",
    })
    append_targets(args, context)

    return {
        command = node_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    reset_parse_state(context)

    local target = target_path(context)
    local cov = effective_coverage_cfg(context)
    local reports_directory = cov.reports_directory or "coverage"
    local report = cov.report or fs.join(reports_directory, "lcov.info")

    local args = build_node_args(context, {
        "--experimental-test-coverage",
        "--test-reporter=spec",
        "--test-reporter=lcov",
        "--test-reporter-destination=stdout",
        "--test-reporter-destination=" .. report,
    })

    if cov.include then
        table.insert(args, "--test-coverage-include=" .. cov.include)
    end
    if cov.exclude then
        table.insert(args, "--test-coverage-exclude=" .. cov.exclude)
    end
    if cov.min_line_rate then
        table.insert(args, "--test-coverage-lines=" .. tostring(cov.min_line_rate))
    end

    append_targets(args, context)

    return {
        command = node_command(context),
        args = args,
        cwd = target,
        report = report,
        reporter = cov.reporter or "msgpack",
        output = cov.output or "coverage/teez.msgpack",
        min_line_rate = cov.min_line_rate,
    }
end

function parse_line(line)
    if line:match("^%s*▶%s+") then
        local suite = trim(line:gsub("^%s*▶%s+", ""))
        if suite ~= "" then
            push_suite(parse_state.suite_stack, suite)
        end
        return nil
    end

    if line:match("^%s*ℹ%s+") or line:match("^%s*#") then
        return nil
    end

    update_current_file_from_failure(line)

    local status, tail, indent = match_result_line(line)
    if not status or not tail then
        return nil
    end

    local name, duration_ms = split_result_tail(tail)
    if indent ~= "" then
        -- Nested result under an active suite.
    elseif #parse_state.suite_stack > 0 and name == parse_state.suite_stack[#parse_state.suite_stack] then
        pop_suite(parse_state.suite_stack)
        return nil
    end

    local id = current_test_id(name)
    if not id or not looks_like_test_id(id) then
        return nil
    end

    consume_parse_test()

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
