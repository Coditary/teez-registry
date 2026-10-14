-- teez playwright adapter

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

local function playwright_command(context)
    if context.runner and context.runner.command then
        return context.runner.command
    end
    return "npx"
end

local function playwright_prefix_args(context)
    if context.runner and context.runner.command then
        return {}
    end
    return { "playwright", "test" }
end

local function append_runner_args(args, context)
    if not context.runner then
        return
    end

    if context.runner.pattern then
        table.insert(args, "-g")
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

local function build_playwright_args(context, extra)
    local args = playwright_prefix_args(context)
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

local function resolve_spec_file(root, filename)
    local normalized = normalize_path(filename)
    if normalized:find("/") then
        return relative_test_path(root, normalized)
    end

    for _, hit in ipairs(fs.glob(root, "**/" .. filename)) do
        return relative_test_path(root, resolve_glob_hit(root, hit))
    end

    return normalized
end

local function normalize_test_id(root, raw_id)
    local file, line, col, title = raw_id:match("^(.-):(%d+):(%d+) › (.+)$")
    if not file then
        return trim(raw_id)
    end

    local resolved = resolve_spec_file(root, file)
    return resolved .. ":" .. line .. ":" .. col .. " › " .. title
end

local function split_result_tail(tail)
    local duration_ms = tail:match("(%d+)ms$")
    if duration_ms then
        local id = trim(tail:gsub("%s+%(%d+ms%)$", ""))
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

local function looks_like_playwright_id(id)
    return id:match(":%d+:%d+ › ") ~= nil
end

local function collect_tests_from_list_output(context, output)
    local tests = {}
    local root = target_path(context)
    local listing = false

    for line in output:gmatch("[^\r\n]+") do
        line = trim(line)
        if line == "Listing tests:" then
            listing = true
        elseif listing and line:match("^Total:") then
            break
        elseif listing and line ~= "" then
            local normalized = normalize_test_id(root, line)
            if looks_like_playwright_id(normalized) then
                table.insert(tests, normalized)
            end
        end
    end

    table.sort(tests)
    return tests
end

local function collect_tests(context)
    local args = build_playwright_args(context, { "--list" })
    append_targets(args, context)

    local output = sys.exec(playwright_command(context), args)
    return collect_tests_from_list_output(context, output)
end

function prefetch_starts()
    return false
end

function list(context)
    return collect_tests(context)
end

function build_command(context)
    local args = build_playwright_args(context, { "--reporter=list" })
    append_targets(args, context)

    return {
        command = playwright_command(context),
        args = args,
    }
end

function build_coverage_run(context)
    -- Playwright Test does not emit LCOV coverage natively. This stub runs the
    -- suite so teez can invoke coverage mode; add monocart-coverage, istanbul,
    -- or similar in playwright.config to produce coverage/lcov.info.
    local target = target_path(context)
    local args = build_playwright_args(context, {
        "--reporter=list",
        "--reporter=json",
    })
    append_targets(args, context)

    return {
        command = playwright_command(context),
        args = args,
        cwd = target,
        report = "coverage/lcov.info",
    }
end

local function match_list_reporter_line(line)
    local prefix, tail = line:match("^(%s+%S+%s+%d+%s+)(.+)$")
    if not prefix or not tail or not looks_like_playwright_id(split_result_tail(tail)) then
        return nil, nil
    end

    if prefix:find("-", 1, true) then
        return "skip", tail
    end
    if prefix:find("✘", 1, true) or prefix:find("×", 1, true) or prefix:find("x", 1, true) then
        return "fail", tail
    end

    return "pass", tail
end

local function match_line_reporter_line(line)
    local progress_tail = line:match("^%[%d+/%d+%]%s+(.+)$")
    if progress_tail and looks_like_playwright_id(progress_tail) then
        return "pass", progress_tail
    end

    return nil, nil
end

function parse_line(line)
    if line:match("^%s*Expected") or line:match("^%s*Received") then
        return nil
    end
    if line:match("^%s*%d+%s+failed") or line:match("^%s*%d+%s+passed") then
        return nil
    end
    if line:match("^%s*Error:") or line:match("^%s*at ") then
        return nil
    end

    local status, tail = match_list_reporter_line(line)
    if not status then
        status, tail = match_line_reporter_line(line)
    end
    if not status or not tail then
        return nil
    end

    local id, duration_ms = split_result_tail(tail)
    if not looks_like_playwright_id(id) then
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
