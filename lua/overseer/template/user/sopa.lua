local function find_justfile_dir()
    local file = vim.fn.findfile("justfile", ".;")

    if file == "" then
        file = vim.fn.findfile("Justfile", ".;")
    end

    if file == "" then
        return nil
    end

    return vim.fn.fnamemodify(file, ":p:h")
end

local tasks = {
    {
        name = "deploy",
        desc = "Deploy SOPA",
        args = { "deploy" },
    },
    {
        name = "deploy-force",
        desc = "Force deploy SOPA",
        args = { "deploy-force" },
    },
}

local function task_names()
    local names = {}

    for _, task in ipairs(tasks) do
        table.insert(names, task.name)
    end

    return names
end

local function find_task(name)
    for _, task in ipairs(tasks) do
        if task.name == name then
            return task
        end
    end

    return nil
end

return {
    name = "SOPA",

    builder = function(params)
        local task = find_task(params.task)

        if task == nil then
            error("Unknown SOPA task: " .. params.task)
        end

        local cwd = find_justfile_dir() or vim.fn.getcwd()

        return {
            cmd = { "just" },
            args = task.args,
            name = "SOPA: " .. task.name,
            cwd = cwd,
            components = {
                "default",
            },
        }
    end,

    params = {
        task = {
            type = "enum",
            name = "Task",
            choices = task_names(),
            default = "deploy",
        },
    },

    condition = {
        callback = function()
            return find_justfile_dir() ~= nil
        end,
    },
}